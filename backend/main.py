"""FastAPI application for Fleet Manager administration and driver sync."""

import hmac
import logging
from collections.abc import Callable
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Annotated

import jwt
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.exception_handlers import http_exception_handler
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import func, select, text
from sqlalchemy.orm import Session, sessionmaker

from backend.config import Settings
from backend.database import build_session_factory, session_dependency
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
from backend.rate_limit import SensitiveRateLimiter
from backend.schemas import (
    AttendanceUpload,
    DeliveryAssignmentCreateRequest,
    DeliveryAssignmentUpdateRequest,
    DeliveryLocationCreateRequest,
    DeliveryLocationUpdateRequest,
    DriverActivateRequest,
    DriverCreateRequest,
    LoginRequest,
    PasswordChangeRequest,
    RefreshRequest,
)
from backend.security import decode_access_token, generate_csrf_token
from backend.services import (
    AppError,
    activate_driver,
    active_assignment_for_driver,
    assignment_detail,
    audit,
    authenticate,
    aware,
    change_password,
    create_assignment,
    create_driver,
    create_location,
    create_session_tokens,
    delete_driver,
    delete_location,
    driver_account,
    get_assignments,
    get_drivers,
    get_locations,
    issue_activation_code,
    latest_completed_assignment_for_driver,
    rotate_refresh,
    set_driver_status,
    store_attendance,
    update_assignment_status,
    update_location,
)

DASHBOARD = Path(__file__).resolve().parent.parent / "dashboard"
ACCESS_COOKIE = "fleet_access"
REFRESH_COOKIE = "fleet_refresh"
CSRF_COOKIE = "fleet_csrf"
LOGGER = logging.getLogger(__name__)


def account_json(account: Account) -> dict[str, object]:
    result: dict[str, object] = {
        "id": account.id,
        "role": account.role,
        "login_id": account.login_id,
        "status": account.status,
        "created_at": account.created_at,
        "disabled_at": account.disabled_at,
    }
    if account.driver_profile:
        result["employee_id"] = account.driver_profile.employee_id
        result["full_name"] = account.driver_profile.full_name
        result["phone"] = account.driver_profile.phone
        result["notes"] = account.driver_profile.notes
    return result


def attendance_json(
    record: AttendanceRecord,
    profile: DriverProfile,
    location: DeliveryLocation | None,
) -> dict[str, object]:
    return {
        "id": record.id,
        "client_attempt_id": record.client_attempt_id,
        "employee_id": profile.employee_id,
        "driver_name": profile.full_name,
        "site_id": record.site_id,
        "site_name": location.name if location else None,
        "captured_at_utc": record.captured_at_utc,
        "server_received_at": record.server_received_at,
        "gps_accuracy_meters": record.gps_accuracy_meters,
        "distance_meters": record.distance_meters,
        "face_score": record.face_score,
        "face_verified": record.face_verified,
        "gps_verified": record.gps_verified,
    }


def location_json(location: DeliveryLocation) -> dict[str, object]:
    return {
        "id": location.id,
        "name": location.name,
        "address": location.address,
        "latitude": location.latitude,
        "longitude": location.longitude,
        "radius_meters": location.radius_meters,
        "active": location.active,
        "created_at": location.created_at,
        "updated_at": location.updated_at,
    }


def assignment_json(assignment: DeliveryAssignment) -> dict[str, object]:
    profile = assignment.driver.driver_profile
    return {
        "id": assignment.id,
        "driver_id": assignment.driver_account_id,
        "employee_id": profile.employee_id,
        "driver_name": profile.full_name,
        "driver_status": assignment.driver.status,
        "location": location_json(assignment.location),
        "assigned_by": assignment.assigned_by_manager_id,
        "assigned_at": assignment.assigned_at,
        "scheduled_at": assignment.scheduled_at,
        "status": assignment.status,
        "notes": assignment.notes,
        "completed_at": assignment.completed_at,
        "updated_at": assignment.updated_at,
    }


def set_manager_cookies(
    response: Response, tokens: dict[str, object], settings: Settings
) -> None:
    cookie = {
        "httponly": True,
        "secure": settings.cookie_secure,
        "samesite": "strict",
        "path": "/",
    }
    response.set_cookie(
        ACCESS_COOKIE,
        str(tokens["access_token"]),
        max_age=int(tokens["expires_in"]),
        **cookie,
    )
    response.set_cookie(
        REFRESH_COOKIE,
        str(tokens["refresh_token"]),
        max_age=settings.refresh_hours * 3600,
        **cookie,
    )
    response.set_cookie(
        CSRF_COOKIE,
        generate_csrf_token(),
        max_age=settings.refresh_hours * 3600,
        secure=settings.cookie_secure,
        httponly=False,
        samesite="strict",
        path="/",
    )


def clear_manager_cookies(response: Response) -> None:
    for name in (ACCESS_COOKIE, REFRESH_COOKIE, CSRF_COOKIE):
        response.delete_cookie(name, path="/")


def create_app(
    settings: Settings | None = None,
    session_factory: sessionmaker[Session] | None = None,
) -> FastAPI:
    settings = settings or Settings.from_env()
    factory = session_factory or build_session_factory(settings.database_url)
    get_db = session_dependency(factory)
    docs = (
        {}
        if settings.enable_api_docs
        else {
            "docs_url": None,
            "redoc_url": None,
            "openapi_url": None,
        }
    )
    app = FastAPI(title="Fleet Manager Portal", version="1.0.0", **docs)
    app.state.settings = settings
    app.state.session_factory = factory
    limiter = SensitiveRateLimiter(
        settings.auth_rate_limit_attempts,
        settings.auth_rate_limit_window_seconds,
    )
    if settings.allowed_hosts:
        app.add_middleware(
            TrustedHostMiddleware, allowed_hosts=list(settings.allowed_hosts)
        )
    if settings.cors_allowed_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=list(settings.cors_allowed_origins),
            allow_credentials=True,
            allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
            allow_headers=[
                "Authorization",
                "Content-Type",
                "Idempotency-Key",
                "X-CSRF-Token",
            ],
        )
    app.mount("/assets", StaticFiles(directory=DASHBOARD), name="assets")

    @app.middleware("http")
    async def release_boundary(request: Request, call_next):
        content_length = request.headers.get("content-length")
        if content_length:
            try:
                if int(content_length) > settings.max_request_bytes:
                    return JSONResponse(
                        {"detail": "Request too large"}, status_code=413
                    )
            except ValueError:
                return JSONResponse({"detail": "Invalid request"}, status_code=400)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Permissions-Policy"] = "camera=(), geolocation=()"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; base-uri 'self'; frame-ancestors 'none'; "
            "form-action 'self'; script-src 'self' https://unpkg.com; "
            "style-src 'self' 'unsafe-inline' https://unpkg.com; "
            "img-src 'self' data: https://unpkg.com https://tile.openstreetmap.org "
            "https://*.tile.openstreetmap.org; "
            "connect-src 'self'"
        )
        if request.url.path.startswith(("/api/", "/attendance/", "/health")):
            response.headers["Cache-Control"] = "no-store"
        if settings.cookie_secure:
            response.headers["Strict-Transport-Security"] = (
                "max-age=31536000; includeSubDomains"
            )
        return response

    @app.exception_handler(AppError)
    async def app_error_handler(_request: Request, error: AppError) -> JSONResponse:
        headers = (
            {"Retry-After": str(settings.auth_rate_limit_window_seconds)}
            if error.status_code == 429
            else None
        )
        return JSONResponse(
            {"detail": error.message}, status_code=error.status_code, headers=headers
        )

    @app.exception_handler(HTTPException)
    async def safe_http_handler(request: Request, error: HTTPException):
        return await http_exception_handler(request, error)

    @app.exception_handler(RequestValidationError)
    async def safe_validation_handler(
        _request: Request, error: RequestValidationError
    ) -> JSONResponse:
        errors = [
            {
                "field": ".".join(str(part) for part in item["loc"]),
                "message": item["msg"],
            }
            for item in error.errors()
        ]
        return JSONResponse(
            {"detail": "Invalid request", "errors": errors}, status_code=422
        )

    @app.exception_handler(Exception)
    async def safe_unhandled_handler(
        _request: Request, error: Exception
    ) -> JSONResponse:
        LOGGER.exception("Unhandled application error", exc_info=error)
        return JSONResponse({"detail": "Internal server error"}, status_code=500)

    def sensitive_keys(
        request: Request, operation: str, subject: str
    ) -> tuple[str, str]:
        host = request.client.host if request.client else "unknown"
        return (
            limiter.subject_key(operation, subject),
            limiter.client_key(operation, host),
        )

    def require_sensitive_attempt(keys: tuple[str, str]) -> None:
        if not limiter.allowed(*keys):
            raise AppError(429, "Too many attempts. Try again later.")

    def token_from_request(request: Request) -> tuple[str | None, bool]:
        authorization = request.headers.get("Authorization", "")
        if authorization.startswith("Bearer "):
            return authorization[7:], False
        return request.cookies.get(ACCESS_COOKIE), True

    def current_account(
        request: Request, db: Session
    ) -> tuple[Account, AuthSession, bool]:
        token, from_cookie = token_from_request(request)
        if not token:
            raise AppError(401, "Session expired")
        try:
            payload = decode_access_token(token, settings)
        except jwt.PyJWTError as error:
            raise AppError(401, "Session expired") from error
        session = db.get(AuthSession, str(payload.get("sid")))
        account = db.get(Account, str(payload.get("sub")))
        if (
            session is None
            or account is None
            or session.account_id != account.id
            or session.revoked_at is not None
            or aware(session.expires_at) <= utcnow()
            or account.status != "active"
            or account.deleted_at is not None
            or account.role != payload.get("role")
        ):
            raise AppError(401, "Session expired")
        return account, session, from_cookie

    def require_role(role: str) -> Callable:
        def dependency(
            request: Request, db: Annotated[Session, Depends(get_db)]
        ) -> Account:
            account, _, _ = current_account(request, db)
            if account.role != role:
                raise AppError(403, "Not authorized")
            if role == "driver":
                account.driver_profile = db.get(DriverProfile, account.id)
            return account

        return dependency

    def require_csrf(request: Request) -> None:
        _, from_cookie = token_from_request(request)
        if not from_cookie:
            return
        cookie = request.cookies.get(CSRF_COOKIE, "")
        header = request.headers.get("X-CSRF-Token", "")
        if not cookie or not header or not hmac.compare_digest(cookie, header):
            raise AppError(403, "Invalid CSRF token")

    manager = require_role("fleet_manager")
    driver = require_role("driver")

    @app.get("/health")
    def health(db: Annotated[Session, Depends(get_db)]) -> dict[str, str]:
        db.execute(text("select 1"))
        return {"status": "ok"}

    @app.post("/api/manager/auth/login")
    def manager_login(
        body: LoginRequest,
        request: Request,
        response: Response,
        db: Annotated[Session, Depends(get_db)],
    ):
        keys = sensitive_keys(request, "manager-login", body.login_id)
        require_sensitive_attempt(keys)
        try:
            account = authenticate(db, body.login_id, body.password, "fleet_manager")
        except AppError:
            limiter.record_failure(*keys)
            raise
        limiter.clear(keys[0])
        tokens = create_session_tokens(
            db, account, settings, body.device_label or "fleet-manager-web"
        )
        set_manager_cookies(response, tokens, settings)
        return {"manager": account_json(account)}

    @app.post("/api/manager/auth/refresh", dependencies=[Depends(require_csrf)])
    def manager_refresh(
        request: Request, response: Response, db: Annotated[Session, Depends(get_db)]
    ):
        raw = request.cookies.get(REFRESH_COOKIE)
        if not raw:
            raise AppError(401, "Session expired")
        account, tokens = rotate_refresh(db, raw, settings, "fleet_manager")
        set_manager_cookies(response, tokens, settings)
        return {"manager": account_json(account)}

    @app.post("/api/manager/auth/logout", dependencies=[Depends(require_csrf)])
    def manager_logout(
        request: Request, response: Response, db: Annotated[Session, Depends(get_db)]
    ):
        account, session, _ = current_account(request, db)
        if account.role != "fleet_manager":
            raise AppError(403, "Not authorized")
        session.revoked_at = utcnow()
        db.commit()
        clear_manager_cookies(response)
        return {"ok": True}

    @app.get("/api/manager/me")
    def manager_me(account: Annotated[Account, Depends(manager)]):
        return {"manager": account_json(account)}

    @app.get("/api/manager/overview")
    def manager_overview(
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        counts = dict(
            db.execute(
                select(Account.status, func.count(Account.id))
                .where(Account.role == "driver", Account.deleted_at.is_(None))
                .group_by(Account.status)
            ).all()
        )
        today = datetime.now(timezone.utc).date()
        attendance_today = db.scalar(
            select(func.count(AttendanceRecord.id)).where(
                AttendanceRecord.captured_at_utc
                >= datetime.combine(today, datetime.min.time(), timezone.utc)
            )
        )
        assignment_counts = dict(
            db.execute(
                select(DeliveryAssignment.status, func.count(DeliveryAssignment.id))
                .where(DeliveryAssignment.status.in_(("assigned", "in_progress")))
                .group_by(DeliveryAssignment.status)
            ).all()
        )
        completed_today = db.scalar(
            select(func.count(DeliveryAssignment.id)).where(
                DeliveryAssignment.completed_at
                >= datetime.combine(today, datetime.min.time(), timezone.utc)
            )
        )
        return {
            "active_drivers": counts.get("active", 0),
            "pending_activation": counts.get("pending_activation", 0),
            "disabled_drivers": counts.get("disabled", 0),
            "attendance_today": attendance_today or 0,
            "pending_deliveries": assignment_counts.get("assigned", 0),
            "in_progress_deliveries": assignment_counts.get("in_progress", 0),
            "completed_today": completed_today or 0,
        }

    @app.get("/api/manager/drivers")
    def list_drivers(
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
        search: str | None = None,
        status: str | None = None,
    ):
        del account
        drivers = get_drivers(db, search, status)
        return {
            "drivers": [account_json(item) for item in drivers],
            "count": len(drivers),
        }

    @app.post(
        "/api/manager/drivers", status_code=201, dependencies=[Depends(require_csrf)]
    )
    def add_driver(
        body: DriverCreateRequest,
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        created, code, expires = create_driver(db, account, body, settings)
        return {
            "driver": account_json(created),
            "activation_code": code,
            "activation_expires_at": expires,
            "activation_code_notice": "Shown once; it cannot be retrieved again.",
        }

    @app.get("/api/manager/drivers/{driver_id}")
    def get_driver(
        driver_id: str,
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        item = driver_account(db, driver_id)
        activation = db.scalar(
            select(ActivationCode)
            .where(
                ActivationCode.driver_account_id == item.id,
                ActivationCode.used_at.is_(None),
                ActivationCode.invalidated_at.is_(None),
            )
            .order_by(ActivationCode.created_at.desc())
        )
        result = account_json(item)
        result["activation"] = (
            {
                "status": "pending",
                "expires_at": activation.expires_at,
                "failed_attempt_count": activation.failed_attempt_count,
            }
            if activation
            else {"status": "activated" if item.status == "active" else "unavailable"}
        )
        current_assignment = db.scalar(
            select(DeliveryAssignment)
            .where(
                DeliveryAssignment.driver_account_id == item.id,
                DeliveryAssignment.status.in_(("assigned", "in_progress")),
            )
            .order_by(DeliveryAssignment.assigned_at.desc())
        )
        if current_assignment:
            result["current_assignment"] = assignment_json(
                assignment_detail(db, current_assignment.id)
            )
        else:
            result["current_assignment"] = None
        return {"driver": result}

    @app.post(
        "/api/manager/drivers/{driver_id}/activation-code",
        dependencies=[Depends(require_csrf)],
    )
    def regenerate_code(
        driver_id: str,
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        item = driver_account(db, driver_id)
        if item.status == "disabled":
            raise AppError(409, "Driver account disabled")
        if item.status == "active":
            raise AppError(409, "Driver is already activated")
        code, expires = issue_activation_code(db, account.id, item.id, settings)
        audit(db, "activation_code_regenerated", item.id, account.id)
        db.commit()
        return {
            "activation_code": code,
            "activation_expires_at": expires,
            "activation_code_notice": "Shown once; it cannot be retrieved again.",
        }

    @app.patch(
        "/api/manager/drivers/{driver_id}/disable", dependencies=[Depends(require_csrf)]
    )
    def disable_driver(
        driver_id: str,
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        return {
            "driver": account_json(
                set_driver_status(
                    db, account, driver_account(db, driver_id), "disabled"
                )
            )
        }

    @app.patch(
        "/api/manager/drivers/{driver_id}/reactivate",
        dependencies=[Depends(require_csrf)],
    )
    def reactivate_driver(
        driver_id: str,
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        item = driver_account(db, driver_id)
        next_status = "active" if item.password_hash else "pending_activation"
        return {
            "driver": account_json(set_driver_status(db, account, item, next_status))
        }

    @app.delete(
        "/api/manager/drivers/{driver_id}", dependencies=[Depends(require_csrf)]
    )
    def remove_driver(
        driver_id: str,
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        item = driver_account(db, driver_id)
        delete_driver(db, account, item)
        return {"deleted": True}

    @app.get("/api/manager/drivers/{driver_id}/audit")
    def driver_audit(
        driver_id: str,
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        driver_account(db, driver_id)
        entries = db.scalars(
            select(AccountAuditLog)
            .where(AccountAuditLog.target_account_id == driver_id)
            .order_by(AccountAuditLog.created_at.desc())
        )
        return {
            "audit": [
                {
                    "id": item.id,
                    "event_type": item.event_type,
                    "metadata": item.safe_metadata,
                    "created_at": item.created_at,
                }
                for item in entries
            ]
        }

    @app.get("/api/manager/audit")
    def manager_audit(
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        entries = db.execute(
            select(AccountAuditLog, DriverProfile)
            .outerjoin(
                DriverProfile,
                DriverProfile.account_id == AccountAuditLog.target_account_id,
            )
            .order_by(AccountAuditLog.created_at.desc())
            .limit(100)
        ).all()
        return {
            "audit": [
                {
                    "id": item.id,
                    "event_type": item.event_type,
                    "target_account_id": item.target_account_id,
                    "driver_name": profile.full_name if profile else None,
                    "employee_id": profile.employee_id if profile else None,
                    "metadata": item.safe_metadata,
                    "created_at": item.created_at,
                }
                for item, profile in entries
            ]
        }

    @app.get("/api/manager/locations")
    def manager_locations(
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
        active: bool | None = None,
    ):
        locations = get_locations(db, active)
        return {
            "locations": [location_json(location) for location in locations],
            "count": len(locations),
        }

    @app.post(
        "/api/manager/locations",
        status_code=201,
        dependencies=[Depends(require_csrf)],
    )
    def add_location(
        body: DeliveryLocationCreateRequest,
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        return {"location": location_json(create_location(db, body))}

    @app.patch(
        "/api/manager/locations/{location_id}",
        dependencies=[Depends(require_csrf)],
    )
    def edit_location(
        location_id: str,
        body: DeliveryLocationUpdateRequest,
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        return {"location": location_json(update_location(db, location_id, body))}

    @app.delete(
        "/api/manager/locations/{location_id}",
        dependencies=[Depends(require_csrf)],
    )
    def remove_location(
        location_id: str,
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        delete_location(db, location_id)
        return {"deleted": True}

    @app.get("/api/manager/deliveries")
    def manager_deliveries(
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
        driver_id: str | None = None,
        status: str | None = None,
        assignment_date: Annotated[date | None, Query(alias="date")] = None,
    ):
        if status and status not in {
            "assigned",
            "in_progress",
            "completed",
            "cancelled",
        }:
            raise AppError(400, "Invalid delivery status")
        start = end = None
        if assignment_date:
            start = datetime.combine(assignment_date, datetime.min.time(), timezone.utc)
            end = datetime.combine(assignment_date, datetime.max.time(), timezone.utc)
        assignments = get_assignments(db, driver_id, status, start, end)
        return {
            "assignments": [assignment_json(item) for item in assignments],
            "count": len(assignments),
        }

    @app.post(
        "/api/manager/deliveries",
        status_code=201,
        dependencies=[Depends(require_csrf)],
    )
    def add_delivery(
        body: DeliveryAssignmentCreateRequest,
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        return {"assignment": assignment_json(create_assignment(db, account, body))}

    @app.get("/api/manager/deliveries/{assignment_id}")
    def get_delivery(
        assignment_id: str,
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        return {"assignment": assignment_json(assignment_detail(db, assignment_id))}

    @app.patch(
        "/api/manager/deliveries/{assignment_id}",
        dependencies=[Depends(require_csrf)],
    )
    def edit_delivery(
        assignment_id: str,
        body: DeliveryAssignmentUpdateRequest,
        account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        return {
            "assignment": assignment_json(
                update_assignment_status(db, account, assignment_id, body.status)
            )
        }

    @app.post("/api/driver/activate")
    def driver_activate(
        body: DriverActivateRequest,
        request: Request,
        db: Annotated[Session, Depends(get_db)],
    ):
        keys = sensitive_keys(request, "driver-activate", body.employee_id)
        require_sensitive_attempt(keys)
        try:
            account = activate_driver(
                db, body.employee_id, body.activation_code, body.password, settings
            )
        except AppError:
            limiter.record_failure(*keys)
            raise
        limiter.clear(keys[0])
        account.driver_profile = db.get(DriverProfile, account.id)
        tokens = create_session_tokens(db, account, settings, body.device_label)
        return {**tokens, "driver": account_json(account)}

    @app.post("/api/driver/auth/login")
    def driver_login(
        body: LoginRequest,
        request: Request,
        db: Annotated[Session, Depends(get_db)],
    ):
        keys = sensitive_keys(request, "driver-login", body.login_id)
        require_sensitive_attempt(keys)
        try:
            account = authenticate(db, body.login_id.upper(), body.password, "driver")
        except AppError:
            limiter.record_failure(*keys)
            raise
        limiter.clear(keys[0])
        account.driver_profile = db.get(DriverProfile, account.id)
        tokens = create_session_tokens(db, account, settings, body.device_label)
        return {**tokens, "driver": account_json(account)}

    @app.post("/api/driver/auth/refresh")
    def driver_refresh(body: RefreshRequest, db: Annotated[Session, Depends(get_db)]):
        if not body.refresh_token:
            raise AppError(401, "Session expired")
        account, tokens = rotate_refresh(db, body.refresh_token, settings, "driver")
        account.driver_profile = db.get(DriverProfile, account.id)
        return {**tokens, "driver": account_json(account)}

    @app.post("/api/driver/auth/logout")
    def driver_logout(
        request: Request,
        _account: Annotated[Account, Depends(driver)],
        db: Annotated[Session, Depends(get_db)],
    ):
        _, session, _ = current_account(request, db)
        session.revoked_at = utcnow()
        db.commit()
        return {"ok": True}

    @app.post("/api/driver/password", status_code=200)
    def driver_password(
        body: PasswordChangeRequest,
        account: Annotated[Account, Depends(driver)],
        db: Annotated[Session, Depends(get_db)],
    ):
        change_password(db, account, body.current_password, body.new_password)
        return {"ok": True}

    @app.get("/api/driver/me")
    def driver_me(
        account: Annotated[Account, Depends(driver)],
        db: Annotated[Session, Depends(get_db)],
    ):
        result = account_json(account)
        assignment = active_assignment_for_driver(db, account.id)
        result["current_assignment"] = (
            assignment_json(assignment) if assignment else None
        )
        recent_delivery = (
            None
            if assignment
            else latest_completed_assignment_for_driver(db, account.id)
        )
        result["recent_delivery"] = (
            assignment_json(recent_delivery) if recent_delivery else None
        )
        return {"driver": result}

    @app.post("/attendance/sync")
    def attendance_sync(
        body: AttendanceUpload,
        request: Request,
        account: Annotated[Account, Depends(driver)],
        db: Annotated[Session, Depends(get_db)],
        idempotency_key: Annotated[str | None, Header()] = None,
    ):
        if idempotency_key != body.client_attempt_id:
            raise AppError(400, "Invalid attendance record")
        record, created = store_attendance(db, account, body, settings)
        return JSONResponse(
            {
                "created": created,
                "synchronized": True,
                "client_attempt_id": record.client_attempt_id,
                "attendance_id": record.id,
            },
            status_code=201 if created else 200,
        )

    @app.get("/api/manager/attendance")
    def manager_attendance(
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
        driver_id: str | None = None,
        attendance_date: Annotated[date | None, Query(alias="date")] = None,
    ):
        query = (
            select(AttendanceRecord, DriverProfile, DeliveryLocation)
            .join(
                DriverProfile,
                DriverProfile.account_id == AttendanceRecord.driver_account_id,
            )
            .outerjoin(
                DeliveryLocation, DeliveryLocation.id == AttendanceRecord.site_id
            )
            .order_by(AttendanceRecord.captured_at_utc.desc())
        )
        if driver_id:
            query = query.where(AttendanceRecord.driver_account_id == driver_id)
        if attendance_date:
            start = datetime.combine(attendance_date, datetime.min.time(), timezone.utc)
            end = datetime.combine(attendance_date, datetime.max.time(), timezone.utc)
            query = query.where(AttendanceRecord.captured_at_utc.between(start, end))
        rows = db.execute(query).all()
        return {
            "attendance": [
                attendance_json(record, profile, location)
                for record, profile, location in rows
            ],
            "count": len(rows),
        }

    @app.get("/api/manager/attendance/{attendance_id}")
    def manager_attendance_detail(
        attendance_id: str,
        _account: Annotated[Account, Depends(manager)],
        db: Annotated[Session, Depends(get_db)],
    ):
        row = db.execute(
            select(AttendanceRecord, DriverProfile, DeliveryLocation)
            .join(
                DriverProfile,
                DriverProfile.account_id == AttendanceRecord.driver_account_id,
            )
            .outerjoin(
                DeliveryLocation, DeliveryLocation.id == AttendanceRecord.site_id
            )
            .where(AttendanceRecord.id == attendance_id)
        ).first()
        if row is None:
            raise AppError(404, "Attendance not found")
        return {"attendance": attendance_json(*row)}

    @app.get("/login", include_in_schema=False)
    def login_page(request: Request):
        with factory() as db:
            try:
                account, _, _ = current_account(request, db)
                if account.role == "fleet_manager":
                    return RedirectResponse("/", status_code=303)
            except AppError:
                pass
        return FileResponse(
            DASHBOARD / "login.html", headers={"Cache-Control": "no-store"}
        )

    @app.get("/", include_in_schema=False)
    @app.get("/drivers", include_in_schema=False)
    @app.get("/drivers/new", include_in_schema=False)
    @app.get("/drivers/{driver_id}", include_in_schema=False)
    @app.get("/attendance", include_in_schema=False)
    @app.get("/deliveries", include_in_schema=False)
    @app.get("/audit", include_in_schema=False)
    def manager_page(request: Request):
        with factory() as db:
            try:
                account, _, _ = current_account(request, db)
                if account.role != "fleet_manager":
                    raise AppError(403, "Not authorized")
            except AppError:
                return RedirectResponse("/login", status_code=303)
        return FileResponse(
            DASHBOARD / "index.html", headers={"Cache-Control": "no-store"}
        )

    return app
