"""Environment-only backend configuration for Supabase PostgreSQL."""

from __future__ import annotations

import os
from dataclasses import dataclass
from urllib.parse import urlsplit


def _csv(name: str) -> tuple[str, ...]:
    return tuple(
        value.strip() for value in os.getenv(name, "").split(",") if value.strip()
    )


def _integer(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError as error:
        raise RuntimeError(f"{name} must be an integer.") from error
    if not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be between {minimum} and {maximum}.")
    return value


@dataclass(frozen=True)
class Settings:
    database_url: str
    jwt_secret: str
    environment: str = "development"
    cookie_secure: bool = False
    access_minutes: int = 15
    refresh_hours: int = 24 * 7
    activation_hours: int = 72
    activation_attempts: int = 5
    attendance_max_age_days: int = 30
    attendance_future_minutes: int = 10
    cors_allowed_origins: tuple[str, ...] = ()
    allowed_hosts: tuple[str, ...] = ()
    auth_rate_limit_attempts: int = 10
    auth_rate_limit_window_seconds: int = 300
    max_request_bytes: int = 65_536
    enable_api_docs: bool = True

    @classmethod
    def from_env(cls) -> Settings:
        database_url = os.getenv("DATABASE_URL", "")
        jwt_secret = os.getenv("JWT_SECRET", "")
        if not database_url or not jwt_secret:
            raise RuntimeError(
                "DATABASE_URL and JWT_SECRET must be configured; see backend/.env.example."
            )
        if database_url.lower().startswith("sqlite"):
            raise RuntimeError(
                "SQLite is test-only; DATABASE_URL must use PostgreSQL/Supabase."
            )
        if not database_url.lower().startswith("postgresql"):
            raise RuntimeError("DATABASE_URL must use PostgreSQL/Supabase.")
        if len(jwt_secret.encode("utf-8")) < 32:
            raise RuntimeError("JWT_SECRET must contain at least 32 bytes.")
        if jwt_secret.startswith("replace-with-"):
            raise RuntimeError("JWT_SECRET still contains the example placeholder.")
        environment = os.getenv("ENVIRONMENT", "development").strip().lower()
        if environment not in {"development", "production"}:
            raise RuntimeError("ENVIRONMENT must be development or production.")
        cookie_secure_value = os.getenv("COOKIE_SECURE", "false").strip().lower()
        if cookie_secure_value not in {"true", "false"}:
            raise RuntimeError("COOKIE_SECURE must be true or false.")
        cookie_secure = cookie_secure_value == "true"
        enable_docs_value = (
            os.getenv(
                "ENABLE_API_DOCS", "false" if environment == "production" else "true"
            )
            .strip()
            .lower()
        )
        if enable_docs_value not in {"true", "false"}:
            raise RuntimeError("ENABLE_API_DOCS must be true or false.")
        allowed_hosts = _csv("ALLOWED_HOSTS")
        cors_allowed_origins = _csv("CORS_ALLOWED_ORIGINS")
        for origin in cors_allowed_origins:
            parsed = urlsplit(origin)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise RuntimeError("CORS_ALLOWED_ORIGINS contains an invalid origin.")
            if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
                raise RuntimeError("CORS_ALLOWED_ORIGINS values must be origins only.")
        if "*" in cors_allowed_origins:
            raise RuntimeError("Wildcard CORS origins are not allowed.")
        if environment == "production":
            if not cookie_secure:
                raise RuntimeError("Production requires COOKIE_SECURE=true.")
            if not allowed_hosts or "*" in allowed_hosts:
                raise RuntimeError(
                    "Production requires explicit ALLOWED_HOSTS without wildcards."
                )
            if "sslmode=require" not in database_url.lower():
                raise RuntimeError(
                    "Production DATABASE_URL must include sslmode=require."
                )
        return cls(
            database_url=database_url,
            jwt_secret=jwt_secret,
            environment=environment,
            cookie_secure=cookie_secure,
            access_minutes=_integer("ACCESS_TOKEN_MINUTES", 15, 1, 60),
            refresh_hours=_integer("REFRESH_TOKEN_HOURS", 168, 1, 24 * 30),
            activation_hours=_integer("ACTIVATION_CODE_HOURS", 72, 1, 24 * 30),
            activation_attempts=_integer("ACTIVATION_MAX_ATTEMPTS", 5, 1, 20),
            attendance_max_age_days=_integer("ATTENDANCE_MAX_AGE_DAYS", 30, 1, 90),
            attendance_future_minutes=_integer("ATTENDANCE_FUTURE_MINUTES", 10, 0, 60),
            cors_allowed_origins=cors_allowed_origins,
            allowed_hosts=allowed_hosts,
            auth_rate_limit_attempts=_integer("AUTH_RATE_LIMIT_ATTEMPTS", 10, 1, 100),
            auth_rate_limit_window_seconds=_integer(
                "AUTH_RATE_LIMIT_WINDOW_SECONDS", 300, 10, 3600
            ),
            max_request_bytes=_integer("MAX_REQUEST_BYTES", 65_536, 1024, 1_048_576),
            enable_api_docs=enable_docs_value == "true",
        )
