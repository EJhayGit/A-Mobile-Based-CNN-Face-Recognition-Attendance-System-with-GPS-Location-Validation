from __future__ import annotations

from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from backend.config import Settings
from backend.database import Base
from backend.main import create_app
from backend.services import bootstrap_manager


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return Settings(
        database_url=f"sqlite:///{tmp_path / 'portal.db'}",
        jwt_secret="synthetic-test-secret-with-at-least-32-bytes",
        access_minutes=15,
        refresh_hours=24,
        activation_hours=72,
        activation_attempts=3,
    )


@pytest.fixture
def factory(settings: Settings) -> sessionmaker[Session]:
    engine = create_engine(
        settings.database_url, connect_args={"check_same_thread": False}
    )
    Base.metadata.create_all(engine)
    return sessionmaker(engine, expire_on_commit=False)


@pytest.fixture
def client(settings: Settings, factory: sessionmaker[Session]) -> TestClient:
    with factory() as db:
        bootstrap_manager(db, "manager_test", "Manager-Test-Password-1!")
    with TestClient(create_app(settings, factory)) as test_client:
        yield test_client


def manager_login(client: TestClient) -> None:
    response = client.post(
        "/api/manager/auth/login",
        json={"login_id": "manager_test", "password": "Manager-Test-Password-1!"},
    )
    assert response.status_code == 200


def csrf(client: TestClient) -> dict[str, str]:
    return {"X-CSRF-Token": client.cookies.get("fleet_csrf")}


def create_driver(client: TestClient, employee_id: str = "TEST-DRV-001") -> dict:
    manager_login(client)
    response = client.post(
        "/api/manager/drivers",
        headers=csrf(client),
        json={"employee_id": employee_id, "full_name": "Test Driver One"},
    )
    assert response.status_code == 201
    return response.json()


def activate_driver(
    client: TestClient, created: dict, password: str = "Driver-Test-Password-1!"
) -> dict:
    response = client.post(
        "/api/driver/activate",
        json={
            "employee_id": created["driver"]["employee_id"],
            "activation_code": created["activation_code"],
            "password": password,
        },
    )
    assert response.status_code == 200
    return response.json()
