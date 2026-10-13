"""Transactional application services shared by API and bootstrap commands."""

from __future__ import annotations

import hmac
import math
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, or_, select, update
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
    DeliveryRouteStop,
    DeviceReplacementRequest,
    DriverProfile,
    FaceReregistrationRequest,
    utcnow,
)
from backend.schemas import (
    AttendanceUpload,
    DeliveryAssignmentCreateRequest,
    DeliveryLocationCreateRequest,
    DeliveryLocationUpdateRequest,
    DeliveryRouteStopsUpdateRequest,
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
    db: Session,
    account: Account,
    settings: Settings,
    device_label: str | None,
    device_fingerprint: str | None = None,
) -> dict[str, object]:
    raw_refresh = generate_refresh_token()
    session = AuthSession(
        account_id=account.id,
        refresh_token_hash=refresh_hash(raw_refresh),
        expires_at=utcnow() + timedelta(hours=settings.refresh_hours),
        device_label=device_label,
        device_fingerprint=device_fingerprint,
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
    db: Session,
    raw_refresh: str,
    settings: Settings,
    expected_role: str | None = None,
    device_fingerprint: str | None = None,
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
    if account.role == "driver":
        profile = db.get(DriverProfile, account.id)
        if (
            profile is None
            or not profile.authorized_device_fingerprint
            or not device_fingerprint
            or not hmac.compare_digest(
                profile.authorized_device_fingerprint, device_fingerprint
            )
            or not session.device_fingerprint
            or not hmac.compare_digest(session.device_fingerprint, device_fingerprint)
        ):
            raise AppError(403, "This device is not authorized for this account")
    session.revoked_at = now
    session.last_used_at = now
    tokens = create_session_tokens(
        db,
        account,
        settings,
        session.device_label,
        device_fingerprint=session.device_fingerprint,
    )
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
    *,
    device_public_key: str,
    device_fingerprint: str,
    device_label: str | None,
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
    profile = db.get(DriverProfile, account.id)
    conflict = db.scalar(
        select(DriverProfile).where(
            DriverProfile.authorized_device_fingerprint == device_fingerprint,
            DriverProfile.account_id != account.id,
        )
    )
    if profile is None or conflict is not None:
        raise AppError(409, "This device is already authorized for another account")
    profile.authorized_device_public_key = device_public_key
    profile.authorized_device_fingerprint = device_fingerprint
    profile.authorized_device_label = device_label
    profile.device_authorized_at = now
    profile.device_authorized_by_manager_id = None
    profile.device_face_enrolled_at = None
    audit(db, "account_activated", account.id, account.id)
    audit(
        db,
        "device_authorized_on_activation",
        account.id,
        account.id,
        {"device_fingerprint_prefix": device_fingerprint[:12]},
    )
    db.commit()
    return account


def require_authorized_device(
    db: Session, account: Account, public_key: str, fingerprint: str
) -> DriverProfile:
    profile = db.get(DriverProfile, account.id)
    if (
        profile is None
        or not profile.authorized_device_public_key
        or not profile.authorized_device_fingerprint
        or not hmac.compare_digest(profile.authorized_device_public_key, public_key)
        or not hmac.compare_digest(profile.authorized_device_fingerprint, fingerprint)
    ):
        raise AppError(403, "This device is not authorized for this account")
    return profile


def request_device_replacement(
    db: Session,
    account: Account,
    *,
    candidate_public_key: str,
    candidate_fingerprint: str,
    device_label: str | None,
) -> DeviceReplacementRequest:
    conflict = db.scalar(
        select(DriverProfile).where(
            DriverProfile.authorized_device_fingerprint == candidate_fingerprint,
            DriverProfile.account_id != account.id,
        )
    )
    if conflict is not None:
        raise AppError(409, "This device is already authorized for another account")
    profile = db.get(DriverProfile, account.id)
    if (
        profile is not None
        and profile.authorized_device_fingerprint
        and hmac.compare_digest(
            profile.authorized_device_fingerprint, candidate_fingerprint
        )
    ):
        raise AppError(409, "This device is already authorized")
    item = db.scalar(
        select(DeviceReplacementRequest).where(
            DeviceReplacementRequest.driver_account_id == account.id
        )
    )
    if item is not None and item.status == "pending":
        raise AppError(409, "A device replacement request is already pending")
    if item is None:
        item = DeviceReplacementRequest(
            driver_account_id=account.id,
            candidate_public_key=candidate_public_key,
            candidate_fingerprint=candidate_fingerprint,
            candidate_device_label=device_label,
        )
        db.add(item)
    else:
        item.candidate_public_key = candidate_public_key
        item.candidate_fingerprint = candidate_fingerprint
        item.candidate_device_label = device_label
        item.status = "pending"
        item.requested_at = utcnow()
        item.decided_at = None
        item.decided_by_manager_id = None
    audit(
        db,
        "device_replacement_requested",
        account.id,
        account.id,
        {"device_fingerprint_prefix": candidate_fingerprint[:12]},
    )
    db.commit()
    return item


def decide_device_replacement(
    db: Session,
    manager: Account,
    item: DeviceReplacementRequest,
    decision: str,
) -> DeviceReplacementRequest:
    if item.status != "pending":
        raise AppError(409, "Device replacement request is no longer pending")
    now = utcnow()
    item.status = "approved" if decision == "approve" else "rejected"
    item.decided_at = now
    item.decided_by_manager_id = manager.id
    if decision == "approve":
        profile = db.scalar(
            select(DriverProfile)
            .where(DriverProfile.account_id == item.driver_account_id)
            .with_for_update()
        )
        if profile is None:
            raise AppError(404, "Field Personnel not found")
        conflict = db.scalar(
            select(DriverProfile).where(
                DriverProfile.authorized_device_fingerprint
                == item.candidate_fingerprint,
                DriverProfile.account_id != item.driver_account_id,
            )
        )
        if conflict is not None:
            raise AppError(409, "This device is already authorized for another account")
        profile.authorized_device_public_key = item.candidate_public_key
        profile.authorized_device_fingerprint = item.candidate_fingerprint
        profile.authorized_device_label = item.candidate_device_label
        profile.device_authorized_at = now
        profile.device_authorized_by_manager_id = manager.id
        profile.device_face_enrolled_at = None
        revoke_sessions(db, item.driver_account_id)
        face_request = db.scalar(
            select(FaceReregistrationRequest).where(
                FaceReregistrationRequest.driver_account_id == item.driver_account_id
            )
        )
        if face_request is not None and face_request.status in {"pending", "approved"}:
            face_request.status = "rejected"
            face_request.decided_at = now
            face_request.decided_by_manager_id = manager.id
            audit(
                db,
                "face_reregistration_invalidated_by_device_replacement",
                item.driver_account_id,
                manager.id,
            )
    audit(
        db,
        f"device_replacement_{item.status}",
        item.driver_account_id,
        manager.id,
        {"device_fingerprint_prefix": item.candidate_fingerprint[:12]},
    )
    db.commit()
    return item


def complete_device_face_enrollment(db: Session, account: Account) -> None:
    profile = db.get(DriverProfile, account.id)
    if profile is None or not profile.authorized_device_fingerprint:
        raise AppError(403, "This device is not authorized for this account")
    if profile.device_face_enrolled_at is None:
        profile.device_face_enrolled_at = utcnow()
        audit(db, "device_face_enrollment_completed", account.id, account.id)
        db.commit()


def _driver_filters(query, search: str | None, status: str | None):
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
    return query


def count_drivers(db: Session, search: str | None, status: str | None) -> int:
    query = (
        select(func.count(Account.id))
        .join(DriverProfile, DriverProfile.account_id == Account.id)
        .where(Account.role == "driver", Account.deleted_at.is_(None))
    )
    return int(db.scalar(_driver_filters(query, search, status)) or 0)


def get_drivers(
    db: Session,
    search: str | None,
    status: str | None,
    *,
    offset: int = 0,
    limit: int | None = None,
    sort: str = "name_asc",
) -> list[Account]:
    query = (
        select(Account)
        .options(selectinload(Account.driver_profile))
        .join(DriverProfile, DriverProfile.account_id == Account.id)
        .where(Account.role == "driver", Account.deleted_at.is_(None))
    )
    query = _driver_filters(query, search, status)
    ordering = {
        "name_asc": (DriverProfile.full_name.asc(), Account.id.asc()),
        "name_desc": (DriverProfile.full_name.desc(), Account.id.asc()),
        "id_asc": (DriverProfile.employee_id.asc(), Account.id.asc()),
        "created_desc": (Account.created_at.desc(), Account.id.asc()),
        "status_asc": (Account.status.asc(), DriverProfile.full_name.asc()),
    }
    query = query.order_by(*ordering.get(sort, ordering["name_asc"])).offset(offset)
    if limit is not None:
        query = query.limit(limit)
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
        raise AppError(404, "Field Personnel not found")
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
            "Cancel the Field Personnel's active Site Assignment before deleting this Field Personnel.",
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


def count_locations(db: Session, active: bool | None = None) -> int:
    query = select(func.count(DeliveryLocation.id)).where(
        DeliveryLocation.deleted_at.is_(None)
    )
    if active is not None:
        query = query.where(DeliveryLocation.active == active)
    return int(db.scalar(query) or 0)


def get_locations(
    db: Session,
    active: bool | None = None,
    *,
    offset: int = 0,
    limit: int | None = None,
    sort: str = "name_asc",
) -> list[DeliveryLocation]:
    query = select(DeliveryLocation).where(DeliveryLocation.deleted_at.is_(None))
    if active is not None:
        query = query.where(DeliveryLocation.active == active)
    ordering = {
        "name_asc": (DeliveryLocation.name.asc(), DeliveryLocation.id.asc()),
        "name_desc": (DeliveryLocation.name.desc(), DeliveryLocation.id.asc()),
        "created_desc": (DeliveryLocation.created_at.desc(), DeliveryLocation.id.asc()),
        "status_asc": (DeliveryLocation.active.desc(), DeliveryLocation.name.asc()),
    }
    query = query.order_by(*ordering.get(sort, ordering["name_asc"])).offset(offset)
    if limit is not None:
        query = query.limit(limit)
    return list(db.scalars(query))


def create_location(
    db: Session, request: DeliveryLocationCreateRequest
) -> DeliveryLocation:
    name = request.name.strip()
    if not name:
        raise AppError(400, "Site Location name is required")
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
        raise AppError(404, "Site Location not found")
    changes = request.model_dump(exclude_unset=True)
    if not changes:
        raise AppError(400, "No Site Location changes supplied")
    for key, value in changes.items():
        if key in {"name", "address"} and isinstance(value, str):
            value = value.strip() or None
        if key == "name" and value is None:
            raise AppError(400, "Site Location name is required")
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
        raise AppError(404, "Site Location not found")
    active_assignment = db.scalar(
        select(DeliveryAssignment.id)
        .outerjoin(
            DeliveryRouteStop,
            DeliveryRouteStop.delivery_assignment_id == DeliveryAssignment.id,
        )
        .where(
            DeliveryAssignment.status.in_(("assigned", "in_progress")),
            or_(
                DeliveryAssignment.delivery_location_id == location.id,
                (
                    (DeliveryRouteStop.delivery_location_id == location.id)
                    & DeliveryRouteStop.removed_at.is_(None)
                ),
            ),
        )
    )
    if active_assignment:
        raise AppError(
            409,
            "Cancel the active Site Assignment before deleting this Site Location.",
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
    *,
    offset: int = 0,
    limit: int | None = None,
    sort: str = "assigned_desc",
) -> list[DeliveryAssignment]:
    query = select(DeliveryAssignment).options(
        selectinload(DeliveryAssignment.driver).selectinload(Account.driver_profile),
        selectinload(DeliveryAssignment.location),
        selectinload(DeliveryAssignment.stops).selectinload(DeliveryRouteStop.location),
    )
    if driver_id:
        query = query.where(DeliveryAssignment.driver_account_id == driver_id)
    if status:
        query = query.where(DeliveryAssignment.status == status)
    if start and end:
        query = query.where(DeliveryAssignment.assigned_at.between(start, end))
    ordering = {
        "assigned_desc": (
            DeliveryAssignment.assigned_at.desc(),
            DeliveryAssignment.id.asc(),
        ),
        "assigned_asc": (
            DeliveryAssignment.assigned_at.asc(),
            DeliveryAssignment.id.asc(),
        ),
        "scheduled_asc": (
            DeliveryAssignment.scheduled_at.asc(),
            DeliveryAssignment.id.asc(),
        ),
        "status_asc": (
            DeliveryAssignment.status.asc(),
            DeliveryAssignment.assigned_at.desc(),
        ),
    }
    query = query.order_by(*ordering.get(sort, ordering["assigned_desc"])).offset(
        offset
    )
    if limit is not None:
        query = query.limit(limit)
    return list(db.scalars(query).unique())


def count_assignments(
    db: Session,
    driver_id: str | None = None,
    status: str | None = None,
    start: datetime | None = None,
    end: datetime | None = None,
) -> int:
    query = select(func.count(DeliveryAssignment.id))
    if driver_id:
        query = query.where(DeliveryAssignment.driver_account_id == driver_id)
    if status:
        query = query.where(DeliveryAssignment.status == status)
    if start and end:
        query = query.where(DeliveryAssignment.assigned_at.between(start, end))
    return int(db.scalar(query) or 0)


def assignment_detail(db: Session, assignment_id: str) -> DeliveryAssignment:
    assignment = db.scalar(
        select(DeliveryAssignment)
        .options(
            selectinload(DeliveryAssignment.driver).selectinload(
                Account.driver_profile
            ),
            selectinload(DeliveryAssignment.location),
            selectinload(DeliveryAssignment.stops).selectinload(
                DeliveryRouteStop.location
            ),
        )
        .where(DeliveryAssignment.id == assignment_id)
    )
    if assignment is None:
        raise AppError(404, "Site Assignment not found")
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
            selectinload(DeliveryAssignment.stops).selectinload(
                DeliveryRouteStop.location
            ),
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
            selectinload(DeliveryAssignment.stops).selectinload(
                DeliveryRouteStop.location
            ),
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
        raise AppError(409, "Only active Field Personnel can receive Site Assignments")
    location_ids = (
        [stop.delivery_location_id for stop in request.stops]
        if request.stops
        else [request.delivery_location_id]
    )
    locations = list(
        db.scalars(
            select(DeliveryLocation).where(
                DeliveryLocation.id.in_(location_ids),
                DeliveryLocation.deleted_at.is_(None),
            )
        )
    )
    locations_by_id = {location.id: location for location in locations}
    if any(location_id not in locations_by_id for location_id in location_ids):
        raise AppError(404, "Site Location not found")
    if any(not locations_by_id[location_id].active for location_id in location_ids):
        raise AppError(409, "Disabled Site Locations cannot receive Site Assignments")
    existing = db.scalar(
        select(DeliveryAssignment.id).where(
            DeliveryAssignment.driver_account_id == driver.id,
            DeliveryAssignment.status.in_(("assigned", "in_progress")),
        )
    )
    if existing:
        raise AppError(409, "Field Personnel already has an active Site Assignment")
    assignment = DeliveryAssignment(
        driver_account_id=driver.id,
        delivery_location_id=location_ids[0],
        assigned_by_manager_id=manager.id,
        scheduled_at=request.scheduled_at,
        route_name=request.route_name.strip() if request.route_name else None,
        notes=request.notes.strip() if request.notes else None,
    )
    db.add(assignment)
    try:
        db.flush()
        for stop_order, location_id in enumerate(location_ids, start=1):
            db.add(
                DeliveryRouteStop(
                    delivery_assignment_id=assignment.id,
                    delivery_location_id=location_id,
                    stop_order=stop_order,
                )
            )
        audit(
            db,
            "delivery_assigned",
            driver.id,
            manager.id,
            {
                "assignment_id": assignment.id,
                "location_id": location_ids[0],
                "stop_count": len(location_ids),
            },
        )
        db.commit()
    except IntegrityError as error:
        db.rollback()
        raise AppError(
            409, "Field Personnel already has an active Site Assignment"
        ) from error
    return assignment_detail(db, assignment.id)


def update_assignment_stops(
    db: Session,
    manager: Account,
    assignment_id: str,
    request: DeliveryRouteStopsUpdateRequest,
) -> DeliveryAssignment:
    assignment = assignment_detail(db, assignment_id)
    active_stops = [stop for stop in assignment.stops if stop.removed_at is None]
    if assignment.status != "assigned" or any(
        stop.completed_at is not None for stop in active_stops
    ):
        raise AppError(409, "Route stops can only be edited before the route starts")
    location_ids = [stop.delivery_location_id for stop in request.stops]
    locations = list(
        db.scalars(
            select(DeliveryLocation).where(
                DeliveryLocation.id.in_(location_ids),
                DeliveryLocation.deleted_at.is_(None),
            )
        )
    )
    locations_by_id = {location.id: location for location in locations}
    if any(location_id not in locations_by_id for location_id in location_ids):
        raise AppError(404, "Site Location not found")
    if any(not locations_by_id[location_id].active for location_id in location_ids):
        raise AppError(409, "Disabled Site Locations cannot receive Site Assignments")
    now = utcnow()
    for stop in active_stops:
        stop.removed_at = now
        stop.updated_at = now
    db.flush()
    for stop_order, location_id in enumerate(location_ids, start=1):
        db.add(
            DeliveryRouteStop(
                delivery_assignment_id=assignment.id,
                delivery_location_id=location_id,
                stop_order=stop_order,
            )
        )
    assignment.delivery_location_id = location_ids[0]
    assignment.updated_at = now
    audit(
        db,
        "delivery_stops_updated",
        assignment.driver_account_id,
        manager.id,
        {"assignment_id": assignment.id, "stop_count": len(location_ids)},
    )
    db.commit()
    db.expire_all()
    return assignment_detail(db, assignment.id)


def update_assignment_status(
    db: Session,
    manager: Account,
    assignment_id: str,
    status: str,
) -> DeliveryAssignment:
    assignment = assignment_detail(db, assignment_id)
    allowed = {
        "assigned": {"in_progress", "cancelled"},
        "in_progress": {"completed", "cancelled"},
        "completed": set(),
        "cancelled": set(),
    }
    if status == assignment.status:
        return assignment
    if status not in allowed[assignment.status]:
        raise AppError(409, "Invalid Site Assignment status transition")
    active_stops = [stop for stop in assignment.stops if stop.removed_at is None]
    if status == "completed" and (
        not active_stops or any(stop.completed_at is None for stop in active_stops)
    ):
        raise AppError(409, "Complete every route stop before completing the route")
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
    if profile is None or profile.device_face_enrolled_at is None:
        raise AppError(403, "Face setup is required on the authorized device")
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
        .options(
            selectinload(DeliveryAssignment.location),
            selectinload(DeliveryAssignment.stops).selectinload(
                DeliveryRouteStop.location
            ),
        )
        .where(
            DeliveryAssignment.driver_account_id == account.id,
            DeliveryAssignment.assigned_at <= captured,
            DeliveryAssignment.status.in_(("assigned", "in_progress")),
        )
        .order_by(DeliveryAssignment.assigned_at.desc())
        .with_for_update()
    )
    if assignment is None:
        raise AppError(400, "Attendance is not for an active Site Assignment")
    if payload.assignment_id and payload.assignment_id != assignment.id:
        raise AppError(400, "Attendance is not for the current Site Assignment")
    active_stops = [stop for stop in assignment.stops if stop.removed_at is None]
    current_stop = next(
        (stop for stop in active_stops if stop.completed_at is None), None
    )
    current_location = current_stop.location if current_stop else assignment.location
    if payload.route_stop_id and (
        current_stop is None or payload.route_stop_id != current_stop.id
    ):
        raise AppError(400, "Attendance is not for the current Site Assignment stop")
    if current_location.id != payload.site_id:
        raise AppError(400, "Attendance is not for the current Site Assignment stop")
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
        current_location.latitude,
        current_location.longitude,
    )
    if distance_meters > current_location.radius_meters:
        raise AppError(400, "Field Personnel is outside the attendance boundary")
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
    if current_stop:
        current_stop.completed_at = completed_at
        current_stop.updated_at = completed_at
    has_pending_stop = any(
        stop.completed_at is None and stop.id != getattr(current_stop, "id", None)
        for stop in active_stops
    )
    assignment.status = "in_progress" if has_pending_stop else "completed"
    assignment.completed_at = None if has_pending_stop else completed_at
    assignment.updated_at = completed_at
    audit(
        db,
        (
            "delivery_stop_completed_by_attendance"
            if has_pending_stop
            else "delivery_completed_by_attendance"
        ),
        account.id,
        account.id,
        {
            "assignment_id": assignment.id,
            "stop_id": current_stop.id if current_stop else None,
            "stop_order": current_stop.stop_order if current_stop else 1,
            "route_completed": not has_pending_stop,
        },
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
