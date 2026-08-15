"""Configuration boundary tests."""

from __future__ import annotations

import pytest

from backend.config import Settings


def test_runtime_configuration_rejects_sqlite(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATABASE_URL", "sqlite:///persistent-local.db")
    monkeypatch.setenv("JWT_SECRET", "synthetic-test-secret")

    with pytest.raises(RuntimeError, match="SQLite is test-only"):
        Settings.from_env()


def test_runtime_configuration_rejects_short_jwt_secret(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+psycopg://app:test@db/postgres")
    monkeypatch.setenv("JWT_SECRET", "too-short")

    with pytest.raises(RuntimeError, match="at least 32 bytes"):
        Settings.from_env()


def test_production_configuration_requires_secure_cookie_and_explicit_hosts(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+psycopg://app:test@db/postgres")
    monkeypatch.setenv("JWT_SECRET", "synthetic-production-secret-at-least-32-bytes")
    monkeypatch.setenv("ENVIRONMENT", "production")
    monkeypatch.setenv("COOKIE_SECURE", "false")
    monkeypatch.setenv("ALLOWED_HOSTS", "api.example.test")

    with pytest.raises(RuntimeError, match="COOKIE_SECURE=true"):
        Settings.from_env()

    monkeypatch.setenv("COOKIE_SECURE", "true")
    monkeypatch.setenv("ALLOWED_HOSTS", "*")
    with pytest.raises(RuntimeError, match="explicit ALLOWED_HOSTS"):
        Settings.from_env()

    monkeypatch.setenv("ALLOWED_HOSTS", "api.example.test")
    with pytest.raises(RuntimeError, match="sslmode=require"):
        Settings.from_env()

    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql+psycopg://app:test@db/postgres?sslmode=require",
    )
    configured = Settings.from_env()
    assert configured.environment == "production"
    assert configured.cookie_secure is True
    assert configured.enable_api_docs is False


def test_configuration_parses_explicit_cors_origins(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DATABASE_URL", "postgresql+psycopg://app:test@db/postgres")
    monkeypatch.setenv("JWT_SECRET", "synthetic-development-secret-at-least-32-bytes")
    monkeypatch.setenv("ENVIRONMENT", "development")
    monkeypatch.setenv("COOKIE_SECURE", "false")
    monkeypatch.setenv(
        "CORS_ALLOWED_ORIGINS", "https://fleet.example.test,http://localhost:5173"
    )

    settings = Settings.from_env()
    assert settings.cors_allowed_origins == (
        "https://fleet.example.test",
        "http://localhost:5173",
    )
