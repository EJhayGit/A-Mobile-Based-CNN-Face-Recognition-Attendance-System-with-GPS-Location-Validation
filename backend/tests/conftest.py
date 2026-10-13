from __future__ import annotations

import base64
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
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


def device_proof(
    client: TestClient,
    login_id: str,
    purpose: str,
    private_key: ec.EllipticCurvePrivateKey | None = None,
) -> tuple[dict[str, str], ec.EllipticCurvePrivateKey]:
    key = private_key or ec.generate_private_key(ec.SECP256R1())
    challenge_response = client.post(
        "/api/driver/auth/device-challenge",
        json={"login_id": login_id, "purpose": purpose},
    )
    assert challenge_response.status_code == 200
    challenge = challenge_response.json()["challenge"]
    public_key = base64.b64encode(
        key.public_key().public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
    ).decode("ascii")
    signature = base64.b64encode(
        key.sign(challenge.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
    ).decode("ascii")
    return (
        {
            "device_public_key": public_key,
            "device_challenge": challenge,
            "device_signature": signature,
            "device_label": "Synthetic Android Device",
        },
        key,
    )


def activate_driver(
    client: TestClient,
    created: dict,
    password: str = "Driver-Test-Password-1!",
    *,
    complete_enrollment: bool = True,
) -> dict:
    employee_id = created["driver"]["employee_id"]
    proof, key = device_proof(client, employee_id, "activate")
    response = client.post(
        "/api/driver/activate",
        json={
            "employee_id": employee_id,
            "activation_code": created["activation_code"],
            "password": password,
            **proof,
        },
    )
    assert response.status_code == 200
    result = response.json()
    result["_device_private_key"] = key
    result["_device_public_key"] = proof["device_public_key"]
    result["_login_id"] = employee_id
    if complete_enrollment:
        completed = client.post(
            "/api/driver/device/enrollment-complete",
            headers={"Authorization": f"Bearer {result['access_token']}"},
        )
        assert completed.status_code == 200
    return result
