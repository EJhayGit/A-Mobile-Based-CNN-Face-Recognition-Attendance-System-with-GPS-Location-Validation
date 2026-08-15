from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from backend.models import AttendanceRecord, DeliveryAssignment
from backend.tests.conftest import activate_driver, create_driver, csrf


def assign_attendance_site(client: TestClient, driver: dict, radius: int = 100) -> dict:
    location_response = client.post(
        "/api/manager/locations",
        headers=csrf(client),
        json={
            "name": "Attendance geofence",
            "latitude": 14.5995,
            "longitude": 120.9842,
            "radius_meters": radius,
        },
    )
    assert location_response.status_code == 201
    location = location_response.json()["location"]
    assignment = client.post(
        "/api/manager/deliveries",
        headers=csrf(client),
        json={"driver_id": driver["id"], "delivery_location_id": location["id"]},
    )
    assert assignment.status_code == 201
    return location


def attendance_payload(
    attempt_id: str,
    driver_id: str = "local-development-driver",
    site_id: str = "depot-1",
) -> dict:
    return {
        "client_attempt_id": attempt_id,
        "driver_id": driver_id,
        "site_id": site_id,
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "latitude": 14.5995,
        "longitude": 120.9842,
        "gps_accuracy_meters": 5.0,
        "distance_meters": 3.0,
        "face_score": 0.75,
        "face_verified": True,
        "gps_verified": True,
    }


def test_attendance_auth_ownership_validation_and_idempotency(
    client: TestClient, factory
):
    created = create_driver(client)
    tokens = activate_driver(client, created)
    location = assign_attendance_site(client, created["driver"], radius=150)
    bearer = {"Authorization": f"Bearer {tokens['access_token']}"}
    payload = attendance_payload("event-one", site_id=location["id"])
    anonymous = TestClient(client.app)
    assert (
        anonymous.post(
            "/attendance/sync", headers={"Idempotency-Key": "event-one"}, json=payload
        ).status_code
        == 401
    )
    assert (
        client.post(
            "/attendance/sync",
            headers={**bearer, "Idempotency-Key": "event-one"},
            json={**payload, "driver_id": "another-driver"},
        ).status_code
        == 403
    )
    responses = [
        client.post(
            "/attendance/sync",
            headers={**bearer, "Idempotency-Key": "event-one"},
            json=payload,
        )
        for _ in range(5)
    ]
    assert [item.status_code for item in responses] == [201, 200, 200, 200, 200]
    assert responses[-1].json()["created"] is False
    conflicting_retry = {**payload, "longitude": payload["longitude"] + 0.0001}
    assert (
        client.post(
            "/attendance/sync",
            headers={**bearer, "Idempotency-Key": "event-one"},
            json=conflicting_retry,
        ).status_code
        == 409
    )
    second = attendance_payload(
        "event-two", created["driver"]["employee_id"], location["id"]
    )
    assert (
        client.post(
            "/attendance/sync",
            headers={**bearer, "Idempotency-Key": "event-two"},
            json=second,
        ).status_code
        == 400
    )
    with factory() as db:
        assert db.scalar(select(func.count(AttendanceRecord.id))) == 1
        assignment = db.scalar(select(DeliveryAssignment))
        assert assignment.status == "completed"
        assert assignment.completed_at is not None
    listing = client.get("/api/manager/attendance")
    assert listing.status_code == 200
    assert listing.json()["count"] == 1
    assert listing.json()["attendance"][0]["client_attempt_id"] == "event-one"
    assert listing.json()["attendance"][0]["site_name"] == "Attendance geofence"
    assert all(item["distance_meters"] == 0 for item in listing.json()["attendance"])
    driver_me = client.get("/api/driver/me", headers=bearer).json()["driver"]
    assert driver_me["current_assignment"] is None
    assert driver_me["recent_delivery"]["status"] == "completed"


def test_server_follows_manager_radius_and_recomputes_distance(
    client: TestClient, factory
):
    created = create_driver(client, "TEST-DRV-GEOFENCE")
    tokens = activate_driver(client, created)
    location = assign_attendance_site(client, created["driver"], radius=250)
    headers = {
        "Authorization": f"Bearer {tokens['access_token']}",
        "Idempotency-Key": "outside",
    }
    outside = attendance_payload("outside", site_id=location["id"])
    outside["latitude"] = 14.6025
    outside["distance_meters"] = 0
    outside["gps_verified"] = True
    assert (
        client.post("/attendance/sync", headers=headers, json=outside).status_code
        == 400
    )

    unassigned = attendance_payload("unassigned", site_id="not-assigned")
    assert (
        client.post(
            "/attendance/sync",
            headers={**headers, "Idempotency-Key": "unassigned"},
            json=unassigned,
        ).status_code
        == 400
    )

    in_radius = attendance_payload("in-radius", site_id=location["id"])
    in_radius["latitude"] = 14.6005
    in_radius["distance_meters"] = 9999
    in_radius["gps_accuracy_meters"] = 120
    response = client.post(
        "/attendance/sync",
        headers={**headers, "Idempotency-Key": "in-radius"},
        json=in_radius,
    )
    assert response.status_code == 201
    with factory() as db:
        record = db.scalar(
            select(AttendanceRecord).where(
                AttendanceRecord.client_attempt_id == "in-radius"
            )
        )
        assert record is not None
        assert record.gps_accuracy_meters == 120
        assert 100 < record.distance_meters < 250


def test_attendance_malformed_timestamp_and_disabled_driver_rejected(
    client: TestClient,
):
    created = create_driver(client)
    tokens = activate_driver(client, created)
    bearer = {"Authorization": f"Bearer {tokens['access_token']}"}
    invalid = attendance_payload("future")
    invalid["captured_at_utc"] = (
        datetime.now(timezone.utc) + timedelta(days=1)
    ).isoformat()
    assert (
        client.post(
            "/attendance/sync",
            headers={**bearer, "Idempotency-Key": "future"},
            json=invalid,
        ).status_code
        == 400
    )
    client.patch(
        f"/api/manager/drivers/{created['driver']['id']}/disable", headers=csrf(client)
    )
    assert (
        client.post(
            "/attendance/sync",
            headers={**bearer, "Idempotency-Key": "disabled"},
            json=attendance_payload("disabled"),
        ).status_code
        == 401
    )


def test_manager_cannot_upload_attendance(client: TestClient):
    create_driver(client)
    assert (
        client.post(
            "/attendance/sync",
            headers={
                "Idempotency-Key": "manager-event",
                "X-CSRF-Token": client.cookies.get("fleet_csrf"),
            },
            json=attendance_payload("manager-event"),
        ).status_code
        == 403
    )


def test_website_pages_protection_rendering_filters_and_no_secrets(client: TestClient):
    anonymous = TestClient(client.app, follow_redirects=False)
    assert anonymous.get("/").status_code == 303
    assert anonymous.get("/login").status_code == 200
    assert "signup" not in anonymous.get("/login").text.lower()
    created = create_driver(client)
    assert client.get("/").status_code == 200
    assert client.get("/drivers").status_code == 200
    assert client.get("/drivers/new").status_code == 200
    detail = client.get(f"/drivers/{created['driver']['id']}")
    assert detail.status_code == 200
    assert client.get("/attendance").status_code == 200
    assert client.get("/deliveries").status_code == 200
    assert client.get("/audit").status_code == 200
    assets = "".join(
        (Path("dashboard") / name).read_text(encoding="utf-8")
        for name in ("index.html", "login.html", "app.js", "login.js")
    ).lower()
    for secret_name in (
        "database_url",
        "jwt_secret",
        "password_hash",
        "code_hash",
        "refresh_token_hash",
    ):
        assert secret_name not in assets
    filtered = client.get(
        "/api/manager/drivers?search=TEST-DRV-001&status=pending_activation"
    )
    assert filtered.status_code == 200
    assert filtered.json()["count"] == 1


def test_database_persists_across_app_recreation(client: TestClient, settings, factory):
    from backend.main import create_app

    created = create_driver(client)
    first_id = created["driver"]["id"]
    with TestClient(create_app(settings, factory)) as restarted:
        login = restarted.post(
            "/api/manager/auth/login",
            json={"login_id": "manager_test", "password": "Manager-Test-Password-1!"},
        )
        assert login.status_code == 200
        drivers = restarted.get("/api/manager/drivers").json()["drivers"]
        assert any(item["id"] == first_id for item in drivers)


def test_migration_declares_required_constraints_and_security():
    migration = next(Path("supabase/migrations").glob("*_backend_manager_portal.sql"))
    sql = migration.read_text(encoding="utf-8").lower()
    for required in (
        "accounts_login_id_key",
        "driver_profiles_employee_id_key",
        "attendance_client_attempt_id_key",
        "references public.accounts",
        "enable row level security",
        "revoke all on table public.attendance_records from anon",
        "create role fleet_backend nologin",
        "attendance_records_backend_policy",
    ):
        assert required in sql
