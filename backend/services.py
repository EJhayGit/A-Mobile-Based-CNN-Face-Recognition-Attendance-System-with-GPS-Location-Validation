"""Transactional application services shared by API and bootstrap commands."""

from __future__ import annotations

import hmac
import math
from datetime import datetime, timedelta, timezone

from sqlalchemy import or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from backend.config import Settings
from backend.models import (
    Account,
    AccountAuditLog,
    ActivationCode,
    AttendanceRecord,
    AuthSession,
    DeliveryAssignment,
    DeliveryLocation,
    DriverProfile,
    utcnow,
)
from backend.schemas import (
    AttendanceUpload,
    DeliveryAssignmentCreateRequest,
    DeliveryLocationCreateRequest,
    DeliveryLocationUpdateRequest,
    DriverCreateRequest,
)
from backend.security import (
    DUMMY_SECRET_HASH,
    create_access_token,
    generate_activation_code,
    generate_refresh_token,
    hash_secret,
    refresh_hash,
    verify_secret,
)


class AppError(Exception):
    def __init__(self, status_code: int, message: str):
        super().__init__(message)
        self.status_code = status_code
        self.message = message


def haversine_meters(
    latitude_a: float,
    longitude_a: float,
    latitude_b: float,
    longitude_b: float,
) -> float:
    earth_radius_meters = 6_371_008.8
    latitude_delta = math.radians(latitude_b - latitude_a)
    longitude_delta = math.radians(longitude_b - longitude_a)
    latitude_a_radians = math.radians(latitude_a)
    latitude_b_radians = math.radians(latitude_b)
    value = (
        math.sin(latitude_delta / 2) ** 2
        + math.cos(latitude_a_radians)
        * math.cos(latitude_b_radians)
        * math.sin(longitude_delta / 2) ** 2
    )
    value = min(1.0, max(0.0, value))
    return earth_radius_meters * 2 * math.atan2(math.sqrt(value), math.sqrt(1 - value))


def aware(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


def audit(
    db: Session,
    event_type: str,
    target_id: str,
    actor_id: str | None,
    metadata: dict[str, object] | None = None,
) -> None:
    db.add(
        AccountAuditLog(
            actor_account_id=actor_id,
            target_account_id=target_id,
            event_type=event_type,
            safe_metadata=metadata or {},
        )
    )


def revoke_sessions(db: Session, account_id: str) -> None:
    db.execute(
        update(AuthSession)
        .where(AuthSession.account_id == account_id, AuthSession.revoked_at.is_(None))
        .values(revoked_at=utcnow())
    )


def bootstrap_manager(db: Session, login_id: str, password: str) -> Account:
    if db.scalar(select(Account.id).where(Account.role == "fleet_manager")):
        raise AppError(409, "A Fleet Manager already exists")
    manager = Account(
        role="fleet_manager",
        login_id=login_id.strip(),
        password_hash=hash_secret(password),
        status="active",
        password_changed_at=utcnow(),
    )
    db.add(manager)
    db.flush()
    audit(db, "manager_bootstrap", manager.id, manager.id)
    db.commit()
    return manager


def authenticate(db: Session, login_id: str, password: str, role: str) -> Account:
    account = db.scalar(
        select(Account)
        .options(selectinload(Account.driver_profile))
        .where(
            Account.login_id == login_id.strip(),
            Account.role == role,
            Account.deleted_at.is_(None),
        )
    )
    valid = verify_secret(
        account.password_hash if account else DUMMY_SECRET_HASH,
        password,
    )
    if not valid or account is None or account.status != "active":
        raise AppError(401, "Invalid login credentials")
    return account


def create_session_tokens(
    db: Session, account: Account, settings: Settings, device_label: str | None
) -> dict[str, object]:
    raw_refresh = generate_refresh_token()
    session = AuthSession(
        account_id=account.id,
        refresh_token_hash=refresh_hash(raw_refresh),
        expires_at=utcnow() + timedelta(hours=settings.refresh_hours),
        device_label=device_label,
    )
    db.add(session)
    db.flush()
    access, expires_in = create_access_token(
        account.id, account.role, session.id, settings
    )
    db.commit()
    return {
        "access_token": access,
        "refresh_token": raw_refresh,
        "token_type": "bearer",
        "expires_in": expires_in,
        "session_id": session.id,
    }


def rotate_refresh(
    db: Session, raw_refresh: str, settings: Settings, expected_role: str | None = None
) -> tuple[Account, dict[str, object]]:
    digest = refresh_hash(raw_refresh)
    session = db.scalar(
        select(AuthSession).where(AuthSession.refresh_token_hash == digest)
    )
    now = utcnow()
    if (
        session is None
        or session.revoked_at is not None
        or aware(session.expires_at) <= now
    ):
        raise AppError(401, "Session expired")
    account = db.get(Account, session.account_id)
    if (
        account is None
        or account.status != "active"
        or account.deleted_at is not None
        or (expected_role and account.role != expected_role)
    ):
        raise AppError(401, "Session expired")
    session.revoked_at = now
    session.last_used_at = now
    tokens = create_session_tokens(db, account, settings, session.device_label)
    return account, tokens


def create_driver(
    db: Session, manager: Account, request: DriverCreateRequest, settings: Settings
) -> tuple[Account, str, datetime]:
    employee_id = request.employee_id.strip().upper()
    account = Account(role="driver", login_id=employee_id, status="pending_activation")
    db.add(account)
    try:
        db.flush()
        db.add(
            DriverProfile(
                account_id=account.id,
                employee_id=employee_id,
                full_name=request.full_name.strip(),
                phone=request.phone.strip() if request.phone else None,
                notes=request.notes.strip() if request.notes else None,
                created_by_manager_id=manager.id,
            )
        )
        code, expires = issue_activation_code(db, manager.id, account.id, settings)
        audit(
            db, "driver_created", account.id, manager.id, {"employee_id": employee_id}
        )
        audit(db, "activation_code_generated", account.id, manager.id)
        db.commit()
    except IntegrityError as error:
        db.rollback()
        raise AppError(409, "Employee ID already exists") from error
    account.driver_profile = db.get(DriverProfile, account.id)
    return account, code, expires


def issue_activation_code(
    db: Session, manager_id: str, driver_id: str, settings: Settings
) -> tuple[str, datetime]:
    now = utcnow()
    db.execute(
        update(ActivationCode)
        .where(
            ActivationCode.driver_account_id == driver_id,
            ActivationCode.used_at.is_(None),
            ActivationCode.invalidated_at.is_(None),
        )
        .values(invalidated_at=now)
    )
    code = generate_activation_code()
    expires = now + timedelta(hours=settings.activation_hours)
    db.add(
        ActivationCode(
            driver_account_id=driver_id,
            code_hash=hash_secret(code),
            expires_at=expires,
            created_by_manager_id=manager_id,
        )
    )
    return code, expires


def activate_driver(
    db: Session,
    employee_id: str,
    code: str,
    password: str,
    settings: Settings,
) -> Account:
    account = db.scalar(
        select(Account)
        .join(DriverProfile, DriverProfile.account_id == Account.id)
        .where(
            DriverProfile.employee_id == employee_id.strip().upper(),
            Account.deleted_at.is_(None),
        )
    )
    generic = AppError(400, "Activation code expired or invalid")
    if account is None or account.status == "disabled" or account.status == "active":
        verify_secret(DUMMY_SECRET_HASH, code.strip().upper())
        raise generic
    activation = db.scalar(
        select(ActivationCode)
        .where(
            ActivationCode.driver_account_id == account.id,
            ActivationCode.used_at.is_(None),
            ActivationCode.invalidated_at.is_(None),
        )
        .order_by(ActivationCode.created_at.desc())
    )
    now = utcnow()
    if (
        activation is None
        or aware(activation.expires_at) <= now
        or activation.failed_attempt_count >= settings.activation_attempts
    ):
        verify_secret(DUMMY_SECRET_HASH, code.strip().upper())
        raise generic
    if not verify_secret(activation.code_hash, code.strip().upper()):
        activation.failed_attempt_count += 1
        if activation.failed_attempt_count >= settings.activation_attempts:
            activation.invalidated_at = now
        db.commit()
        raise generic
    activation.used_at = now
    account.password_hash = hash_secret(password)
    account.password_changed_at = now
    account.status = "active"
    audit(db, "account_activated", account.id, account.id)
    db.commit()
    return account


def get_drivers(db: Session, search: str | None, status: str | None) -> list[Account]:
    query = (
        select(Account)
        .options(selectinload(Account.driver_profile))
        .join(DriverProfile, DriverProfile.account_id == Account.id)
        .where(Account.role == "driver", Account.deleted_at.is_(None))
        .order_by(DriverProfile.full_name)
    )
    if search:
        term = f"%{search.strip()}%"
        query = query.where(
            or_(
                DriverProfile.employee_id.ilike(term),
                DriverProfile.full_name.ilike(term),
            )
        )
    if status:
        query = query.where(Account.status == status)
    return list(db.scalars(query).unique())


def driver_account(db: Session, driver_id: str) -> Account:
    account = db.scalar(
        select(Account)
        .options(selectinload(Account.driver_profile))
        .where(
            Account.id == driver_id,
            Account.role == "driver",
            Account.deleted_at.is_(None),
        )
    )
    if account is None:
        raise AppError(404, "Driver not found")
    return account


def set_driver_status(
    db: Session, manager: Account, driver: Account, status: str
) -> Account:
    now = utcnow()
    driver.status = status
    driver.disabled_at = now if status == "disabled" else None
    revoke_sessions(db, driver.id)
    if status == "disabled":
        db.execute(
            update(ActivationCode)
            .where(
                ActivationCode.driver_account_id == driver.id,
                ActivationCode.used_at.is_(None),
                ActivationCode.invalidated_at.is_(None),
            )
            .values(invalidated_at=now)
        )
    event = "account_disabled" if status == "disabled" else "account_reactivated"
    audit(db, event, driver.id, manager.id)
    db.commit()
    return driver


def delete_driver(db: Session, manager: Account, driver: Account) -> None:
    active_assignment = db.scalar(
        select(DeliveryAssignment.id).where(
            DeliveryAssignment.driver_account_id == driver.id,
            DeliveryAssignment.status.in_(("assigned", "in_progress")),
        )
    )
    if active_assignment:
        raise AppError(
            409,
            "Cancel the Driver's active route before deleting this Driver.",
        )
    now = utcnow()
    driver.status = "disabled"
    driver.disabled_at = now
    driver.deleted_at = now
    driver.updated_at = now
    revoke_sessions(db, driver.id)
    db.execute(
        update(ActivationCode)
        .where(
            ActivationCode.driver_account_id == driver.id,
            ActivationCode.used_at.is_(None),
            ActivationCode.invalidated_at.is_(None),
        )
        .values(invalidated_at=now)
    )
    audit(db, "driver_deleted", driver.id, manager.id)
    db.commit()


def change_password(db: Session, account: Account, current: str, new: str) -> None:
    if not verify_secret(account.password_hash, current):
        raise AppError(401, "Invalid login credentials")
    account.password_hash = hash_secret(new)
    account.password_changed_at = utcnow()
    revoke_sessions(db, account.id)
    audit(db, "password_changed", account.id, account.id)
    db.commit()


def get_locations(db: Session, active: bool | None = None) -> list[DeliveryLocation]:
    query = (
        select(DeliveryLocation)
        .where(DeliveryLocation.deleted_at.is_(None))
        .order_by(DeliveryLocation.name)
    )
    if active is not None:
        query = query.where(DeliveryLocation.active == active)
    return list(db.scalars(query))


def create_location(
    db: Session, request: DeliveryLocationCreateRequest
) -> DeliveryLocation:
    name = request.name.strip()
    if not name:
        raise AppError(400, "Location name is required")
    location = DeliveryLocation(
        name=name,
        address=request.address.strip() if request.address else None,
        latitude=request.latitude,
        longitude=request.longitude,
        radius_meters=request.radius_meters,
    )
    db.add(location)
    db.commit()
    return location


def update_location(
    db: Session,
    location_id: str,
    request: DeliveryLocationUpdateRequest,
) -> DeliveryLocation:
    location = db.scalar(
        select(DeliveryLocation).where(
            DeliveryLocation.id == location_id,
            DeliveryLocation.deleted_at.is_(None),
        )
    )
    if location is None:
        raise AppError(404, "Delivery location not found")
    changes = request.model_dump(exclude_unset=True)
    if not changes:
        raise AppError(400, "No delivery location changes supplied")
    for key, value in changes.items():
        if key in {"name", "address"} and isinstance(value, str):
            value = value.strip() or None
        if key == "name" and value is None:
            raise AppError(400, "Location name is required")
        setattr(location, key, value)
    db.commit()
    return location


def delete_location(db: Session, location_id: str) -> None:
    location = db.scalar(
        select(DeliveryLocation).where(
            DeliveryLocation.id == location_id,
            DeliveryLocation.deleted_at.is_(None),
        )
    )
    if location is None:
        raise AppError(404, "Delivery location not found")
    active_assignment = db.scalar(
        select(DeliveryAssignment.id).where(
            DeliveryAssignment.delivery_location_id == location.id,
            DeliveryAssignment.status.in_(("assigned", "in_progress")),
        )
    )
    if active_assignment:
        raise AppError(
            409,
            "Cancel the active route before deleting this Location.",
        )
    now = utcnow()
    location.active = False
    location.deleted_at = now
    location.updated_at = now
    db.commit()


def get_assignments(
    db: Session,
    driver_id: str | None = None,
    status: str | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
) -> list[DeliveryAssignment]:
    query = (
        select(DeliveryAssignment)
        .options(
            selectinload(DeliveryAssignment.driver).selectinload(
                Account.driver_profile
            ),
            selectinload(DeliveryAssignment.location),
        )
        .order_by(DeliveryAssignment.assigned_at.desc())
    )
    if driver_id:
        query = query.where(DeliveryAssignment.driver_account_id == driver_id)
    if status:
        query = query.where(DeliveryAssignment.status == status)
    if start and end:
        query = query.where(DeliveryAssignment.assigned_at.between(start, end))
    return list(db.scalars(query).unique())


def assignment_detail(db: Session, assignment_id: str) -> DeliveryAssignment:
    assignment = db.scalar(
        select(DeliveryAssignment)
        .options(
            selectinload(DeliveryAssignment.driver).selectinload(
                Account.driver_profile
            ),
            selectinload(DeliveryAssignment.location),
        )
        .where(DeliveryAssignment.id == assignment_id)
    )
    if assignment is None:
        raise AppError(404, "Delivery assignment not found")
    return assignment


def active_assignment_for_driver(
    db: Session, driver_id: str
) -> DeliveryAssignment | None:
    return db.scalar(
        select(DeliveryAssignment)
        .options(
            selectinload(DeliveryAssignment.driver).selectinload(
                Account.driver_profile
            ),
            selectinload(DeliveryAssignment.location),
        )
        .where(
            DeliveryAssignment.driver_account_id == driver_id,
            DeliveryAssignment.status.in_(("assigned", "in_progress")),
        )
        .order_by(DeliveryAssignment.assigned_at.desc())
    )


def latest_completed_assignment_for_driver(
    db: Session, driver_id: str
) -> DeliveryAssignment | None:
    return db.scalar(
        select(DeliveryAssignment)
        .options(
            selectinload(DeliveryAssignment.driver).selectinload(
                Account.driver_profile
            ),
            selectinload(DeliveryAssignment.location),
        )
        .where(
            DeliveryAssignment.driver_account_id == driver_id,
            DeliveryAssignment.status == "completed",
        )
        .order_by(DeliveryAssignment.completed_at.desc())
    )


def create_assignment(
    db: Session,
    manager: Account,
    request: DeliveryAssignmentCreateRequest,
) -> DeliveryAssignment:
    driver = driver_account(db, request.driver_id)
    if driver.status != "active":
        raise AppError(409, "Only active Drivers can receive assignments")
    location = db.scalar(
        select(DeliveryLocation).where(
            DeliveryLocation.id == request.delivery_location_id,
            DeliveryLocation.deleted_at.is_(None),
        )
    )
    if location is None:
        raise AppError(404, "Delivery location not found")
    if not location.active:
        raise AppError(409, "Disabled Locations cannot receive assignments")
    existing = db.scalar(
        select(DeliveryAssignment.id).where(
            DeliveryAssignment.driver_account_id == driver.id,
            DeliveryAssignment.status.in_(("assigned", "in_progress")),
        )
    )
    if existing:
        raise AppError(409, "Driver already has an active delivery assignment")
    assignment = DeliveryAssignment(
        driver_account_id=driver.id,
        delivery_location_id=location.id,
        assigned_by_manager_id=manager.id,
        scheduled_at=request.scheduled_at,
        notes=request.notes.strip() if request.notes else None,
    )
    db.add(assignment)
    try:
        db.flush()
        audit(
            db,
            "delivery_assigned",
            driver.id,
            manager.id,
            {"assignment_id": assignment.id, "location_id": location.id},
        )
        db.commit()
    except IntegrityError as error:
        db.rollback()
        raise AppError(
            409, "Driver already has an active delivery assignment"
        ) from error
    return assignment_detail(db, assignment.id)


def update_assignment_status(
    db: Session,
    manager: Account,
    assignment_id: str,
    status: str,
) -> DeliveryAssignment:
    assignment = assignment_detail(db, assignment_id)
    allowed = {
        "assigned": {"in_progress", "completed", "cancelled"},
        "in_progress": {"completed", "cancelled"},
        "completed": set(),
        "cancelled": set(),
    }
    if status == assignment.status:
        return assignment
    if status not in allowed[assignment.status]:
        raise AppError(409, "Invalid delivery status transition")
    assignment.status = status
    assignment.completed_at = utcnow() if status == "completed" else None
    assignment.updated_at = utcnow()
    audit(
        db,
        f"delivery_{status}",
        assignment.driver_account_id,
        manager.id,
        {"assignment_id": assignment.id},
    )
    db.commit()
    return assignment_detail(db, assignment.id)


def store_attendance(
    db: Session, account: Account, payload: AttendanceUpload, settings: Settings
) -> tuple[AttendanceRecord, bool]:
    profile = db.get(DriverProfile, account.id)
    allowed_driver_ids = {account.id, profile.employee_id, "local-development-driver"}
    if payload.driver_id not in allowed_driver_ids:
        raise AppError(403, "Invalid attendance record")
    if not payload.face_verified or not payload.gps_verified:
        raise AppError(400, "Invalid attendance record")
    captured = payload.captured_at_utc.astimezone(timezone.utc)
    now = utcnow()
    if captured < now - timedelta(
        days=settings.attendance_max_age_days
    ) or captured > now + timedelta(minutes=settings.attendance_future_minutes):
        raise AppError(400, "Invalid attendance record")
    existing = db.scalar(
        select(AttendanceRecord).where(
            AttendanceRecord.client_attempt_id == payload.client_attempt_id
        )
    )
    values = payload.model_dump()
    if existing:
        same = (
            existing.driver_account_id == account.id
            and existing.client_driver_id == payload.driver_id
            and existing.site_id == payload.site_id
            and aware(existing.captured_at_utc) == captured
            and all(
                hmac.compare_digest(str(getattr(existing, key)), str(values[key]))
                for key in (
                    "latitude",
                    "longitude",
                    "gps_accuracy_meters",
                    "face_score",
                    "face_verified",
                    "gps_verified",
                )
            )
        )
        if not same:
            raise AppError(409, "Idempotency key was reused with different content")
        return existing, False
    assignment = db.scalar(
        select(DeliveryAssignment)
        .options(selectinload(DeliveryAssignment.location))
        .where(
            DeliveryAssignment.driver_account_id == account.id,
            DeliveryAssignment.delivery_location_id == payload.site_id,
            DeliveryAssignment.assigned_at <= captured,
            or_(
                DeliveryAssignment.status.in_(("assigned", "in_progress")),
                DeliveryAssignment.updated_at >= captured,
            ),
        )
        .order_by(DeliveryAssignment.assigned_at.desc())
        .with_for_update()
    )
    if assignment is None:
        raise AppError(400, "Attendance is not for an assigned location")
    if not all(
        math.isfinite(value)
        for value in (
            payload.latitude,
            payload.longitude,
            payload.gps_accuracy_meters,
        )
    ):
        raise AppError(400, "Invalid GPS reading")
    distance_meters = haversine_meters(
        payload.latitude,
        payload.longitude,
        assignment.location.latitude,
        assignment.location.longitude,
    )
    if distance_meters > assignment.location.radius_meters:
        raise AppError(400, "Driver is outside the attendance boundary")
    record = AttendanceRecord(
        client_attempt_id=payload.client_attempt_id,
        driver_account_id=account.id,
        client_driver_id=payload.driver_id,
        site_id=payload.site_id,
        captured_at_utc=captured,
        latitude=payload.latitude,
        longitude=payload.longitude,
        gps_accuracy_meters=payload.gps_accuracy_meters,
        distance_meters=distance_meters,
        face_score=payload.face_score,
        face_verified=payload.face_verified,
        gps_verified=True,
    )
    db.add(record)
    completed_at = utcnow()
    assignment.status = "completed"
    assignment.completed_at = completed_at
    assignment.updated_at = completed_at
    audit(
        db,
        "delivery_completed_by_attendance",
        account.id,
        account.id,
        {"assignment_id": assignment.id},
    )
    try:
        db.commit()
        return record, True
    except IntegrityError:
        db.rollback()
        concurrent = db.scalar(
            select(AttendanceRecord).where(
                AttendanceRecord.client_attempt_id == payload.client_attempt_id
            )
        )
        if concurrent is None:
            raise
        return concurrent, False
