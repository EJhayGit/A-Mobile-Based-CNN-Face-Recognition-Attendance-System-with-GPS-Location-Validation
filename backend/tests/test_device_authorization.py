from __future__ import annotations

from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import select

from backend.models import AuthSession, DriverProfile
from backend.tests.conftest import (
    activate_driver,
    create_driver,
    csrf,
    device_proof,
    manager_login,
)


def bearer(session: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {session['access_token']}"}


def login_payload(
    client: TestClient,
    login_id: str,
    password: str,
    private_key,
) -> dict:
    proof, _ = device_proof(client, login_id, "login", private_key)
    return {"login_id": login_id, "password": password, **proof}


def replacement_payload(
    client: TestClient,
    login_id: str,
    password: str,
    private_key=None,
) -> tuple[dict, object]:
    proof, key = device_proof(client, login_id, "replace", private_key)
    return ({"login_id": login_id, "password": password, **proof}, key)


def test_activation_binds_device_and_requires_face_setup(client: TestClient) -> None:
    session = activate_driver(
        client, create_driver(client, "DEVICE-001"), complete_enrollment=False
    )
    profile = client.get("/api/driver/me", headers=bearer(session)).json()["driver"]
    assert profile["device_authorization"]["status"] == "enrollment_required"
    assert profile["device_authorization"]["fingerprint_prefix"]

    blocked = client.post(
        "/attendance/sync",
        headers={**bearer(session), "Idempotency-Key": "device-setup-required"},
        json={
            "client_attempt_id": "device-setup-required",
            "driver_id": "DEVICE-001",
            "site_id": "unknown",
            "captured_at_utc": "2026-09-10T01:00:00Z",
            "latitude": 14.5,
            "longitude": 121.0,
            "gps_accuracy_meters": 5,
            "distance_meters": 0,
            "face_score": 0.9,
            "face_verified": True,
            "gps_verified": True,
        },
    )
    assert blocked.status_code == 403
    assert blocked.json()["detail"] == "Face setup is required on the authorized device"

    completed = client.post(
        "/api/driver/device/enrollment-complete", headers=bearer(session)
    )
    assert completed.status_code == 200
    ready = client.get("/api/driver/me", headers=bearer(session)).json()["driver"]
    assert ready["device_authorization"]["status"] == "ready"


def test_only_bound_device_can_login_and_one_device_cannot_bind_two_accounts(
    client: TestClient, factory
) -> None:
    first = create_driver(client, "DEVICE-FIRST")
    session = activate_driver(client, first)

    other_proof, _ = device_proof(client, "DEVICE-FIRST", "login")
    rejected = client.post(
        "/api/driver/auth/login",
        json={
            "login_id": "DEVICE-FIRST",
            "password": "Driver-Test-Password-1!",
            **other_proof,
        },
    )
    assert rejected.status_code == 403
    assert rejected.json()["detail"] == "This device is not authorized for this account"

    foreign_refresh, _ = device_proof(client, "DEVICE-FIRST", "refresh")
    refresh_rejected = client.post(
        "/api/driver/auth/refresh",
        json={
            "refresh_token": session["refresh_token"],
            "login_id": "DEVICE-FIRST",
            **foreign_refresh,
        },
    )
    assert refresh_rejected.status_code == 403
    assert client.get("/api/driver/me", headers=bearer(session)).status_code == 200

    wrong_purpose, _ = device_proof(
        client, "DEVICE-FIRST", "replace", session["_device_private_key"]
    )
    invalid_challenge = client.post(
        "/api/driver/auth/login",
        json={
            "login_id": "DEVICE-FIRST",
            "password": "Driver-Test-Password-1!",
            **wrong_purpose,
        },
    )
    assert invalid_challenge.status_code == 401

    accepted = client.post(
        "/api/driver/auth/login",
        json=login_payload(
            client,
            "DEVICE-FIRST",
            "Driver-Test-Password-1!",
            session["_device_private_key"],
        ),
    )
    assert accepted.status_code == 200

    second = create_driver(client, "DEVICE-SECOND")
    proof, _ = device_proof(
        client, "DEVICE-SECOND", "activate", session["_device_private_key"]
    )
    duplicate_device = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "DEVICE-SECOND",
            "activation_code": second["activation_code"],
            "password": "Driver-Test-Password-2!",
            **proof,
        },
    )
    assert duplicate_device.status_code == 400
    with factory() as db:
        second_profile = db.scalar(
            select(DriverProfile).where(DriverProfile.employee_id == "DEVICE-SECOND")
        )
        assert second_profile.authorized_device_fingerprint is None
        assert second_profile.account.status == "pending_activation"


def test_manager_approved_replacement_revokes_old_device_and_requires_new_setup(
    client: TestClient, factory
) -> None:
    created = create_driver(client, "DEVICE-REPLACE")
    old_session = activate_driver(client, created)
    request_body, new_key = replacement_payload(
        client, "DEVICE-REPLACE", "Driver-Test-Password-1!"
    )
    requested = client.post("/api/driver/device-replacement-request", json=request_body)
    assert requested.status_code == 201
    request_id = requested.json()["request"]["id"]

    manager_login(client)
    listed = client.get("/api/manager/device-replacement-requests")
    assert listed.status_code == 200
    assert listed.json()["requests"][0]["employee_id"] == "DEVICE-REPLACE"
    assert listed.json()["requests"][0]["status"] == "pending"
    approved = client.patch(
        f"/api/manager/device-replacement-requests/{request_id}",
        headers=csrf(client),
        json={"decision": "approve"},
    )
    assert approved.status_code == 200
    assert approved.json()["request"]["status"] == "approved"

    assert client.get("/api/driver/me", headers=bearer(old_session)).status_code == 401
    old_login = client.post(
        "/api/driver/auth/login",
        json=login_payload(
            client,
            "DEVICE-REPLACE",
            "Driver-Test-Password-1!",
            old_session["_device_private_key"],
        ),
    )
    assert old_login.status_code == 403

    new_login = client.post(
        "/api/driver/auth/login",
        json=login_payload(
            client,
            "DEVICE-REPLACE",
            "Driver-Test-Password-1!",
            new_key,
        ),
    )
    assert new_login.status_code == 200
    assert (
        new_login.json()["driver"]["device_authorization"]["status"]
        == "enrollment_required"
    )
    with factory() as db:
        active_sessions = list(
            db.scalars(
                select(AuthSession).where(
                    AuthSession.account_id == created["driver"]["id"],
                    AuthSession.revoked_at.is_(None),
                )
            )
        )
        assert len(active_sessions) == 1
        assert active_sessions[0].device_fingerprint is not None


def test_rejected_replacement_keeps_existing_device_authorized(
    client: TestClient,
) -> None:
    created = create_driver(client, "DEVICE-REJECT")
    session = activate_driver(client, created)
    request_body, candidate_key = replacement_payload(
        client, "DEVICE-REJECT", "Driver-Test-Password-1!"
    )
    request_id = client.post(
        "/api/driver/device-replacement-request", json=request_body
    ).json()["request"]["id"]
    manager_login(client)
    rejected = client.patch(
        f"/api/manager/device-replacement-requests/{request_id}",
        headers=csrf(client),
        json={"decision": "reject"},
    )
    assert rejected.status_code == 200

    old_login = client.post(
        "/api/driver/auth/login",
        json=login_payload(
            client,
            "DEVICE-REJECT",
            "Driver-Test-Password-1!",
            session["_device_private_key"],
        ),
    )
    assert old_login.status_code == 200
    candidate_login = client.post(
        "/api/driver/auth/login",
        json=login_payload(
            client,
            "DEVICE-REJECT",
            "Driver-Test-Password-1!",
            candidate_key,
        ),
    )
    assert candidate_login.status_code == 403


def test_logout_revokes_session_but_same_authorized_device_can_log_in_again(
    client: TestClient,
) -> None:
    session = activate_driver(client, create_driver(client, "DEVICE-LOGOUT"))
    logged_out = client.post("/api/driver/auth/logout", headers=bearer(session))
    assert logged_out.status_code == 200
    assert client.get("/api/driver/me", headers=bearer(session)).status_code == 401

    logged_in = client.post(
        "/api/driver/auth/login",
        json=login_payload(
            client,
            "DEVICE-LOGOUT",
            "Driver-Test-Password-1!",
            session["_device_private_key"],
        ),
    )
    assert logged_in.status_code == 200


def test_device_authorization_migration_and_dashboard_store_no_biometrics() -> None:
    migration = Path(
        "supabase/migrations/20260910090000_driver_device_authorization.sql"
    ).read_text(encoding="utf-8")
    dashboard = Path("dashboard/app.js").read_text(encoding="utf-8")
    lowered = migration.lower()
    assert "authorized_device_public_key" in lowered
    assert "device_replacement_requests" in lowered
    assert "enable row level security" in lowered
    assert "to fleet_backend" in lowered
    assert "face_embedding" not in lowered
    assert "face_image" not in lowered
    assert "Device replacement requests" in dashboard
    assert 'data-device-decision="approve"' in dashboard
    assert 'data-device-decision="reject"' in dashboard
    assert "sign out the old phone" in dashboard
