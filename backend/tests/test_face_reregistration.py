from pathlib import Path

from fastapi.testclient import TestClient

from backend.tests.conftest import activate_driver, create_driver, csrf, manager_login


def bearer(session: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {session['access_token']}"}


def test_driver_request_duplicate_and_manager_approval_are_driver_bound(
    client: TestClient,
) -> None:
    first = create_driver(client, "FACE-001")
    first_session = activate_driver(client, first)
    second = create_driver(client, "FACE-002")
    second_session = activate_driver(client, second)

    created = client.post(
        "/api/driver/face-reregistration-request", headers=bearer(first_session)
    )
    assert created.status_code == 201
    request_id = created.json()["request"]["id"]
    assert created.json()["request"]["driver_id"] == first["driver"]["id"]
    assert created.json()["request"]["status"] == "pending"

    duplicate = client.post(
        "/api/driver/face-reregistration-request", headers=bearer(first_session)
    )
    assert duplicate.status_code == 409

    manager_login(client)
    pending = client.get("/api/manager/face-reregistration-requests")
    assert pending.json()["count"] == 1
    listed = pending.json()["requests"][0]
    assert listed["id"] == request_id
    assert listed["driver_name"] == "Test Driver One"
    assert listed["employee_id"] == "FACE-001"
    assert listed["status"] == "pending"
    approved = client.patch(
        f"/api/manager/face-reregistration-requests/{request_id}",
        headers=csrf(client),
        json={"decision": "approve"},
    )
    assert approved.status_code == 200
    assert approved.json()["request"]["status"] == "approved"

    wrong_driver = client.post(
        "/api/driver/face-reregistration-request/consume",
        headers=bearer(second_session),
    )
    assert wrong_driver.status_code == 403
    own_profile = client.get("/api/driver/me", headers=bearer(first_session))
    assert (
        own_profile.json()["driver"]["face_reregistration_request"]["status"]
        == "approved"
    )

    consumed = client.post(
        "/api/driver/face-reregistration-request/consume",
        headers=bearer(first_session),
    )
    assert consumed.status_code == 200
    assert consumed.json()["request"]["status"] == "consumed"
    assert (
        client.post(
            "/api/driver/face-reregistration-request/consume",
            headers=bearer(first_session),
        ).status_code
        == 403
    )


def test_manager_can_reject_and_driver_can_request_again(client: TestClient) -> None:
    created = create_driver(client, "FACE-REJECT")
    session = activate_driver(client, created)
    request = client.post(
        "/api/driver/face-reregistration-request", headers=bearer(session)
    ).json()["request"]
    manager_login(client)
    rejected = client.patch(
        f"/api/manager/face-reregistration-requests/{request['id']}",
        headers=csrf(client),
        json={"decision": "reject"},
    )
    assert rejected.status_code == 200
    assert rejected.json()["request"]["status"] == "rejected"
    retried = client.post(
        "/api/driver/face-reregistration-request", headers=bearer(session)
    )
    assert retried.status_code == 201
    assert retried.json()["request"]["status"] == "pending"


def test_face_reregistration_migration_and_dashboard_are_biometric_free() -> None:
    migration = (
        Path("supabase/migrations/20260823090000_face_reregistration_approval.sql")
        .read_text(encoding="utf-8")
        .lower()
    )
    dashboard = Path("dashboard/app.js").read_text(encoding="utf-8")
    assert "face_reregistration_requests" in migration
    assert "driver_account_id text not null unique" in migration
    assert "enable row level security" in migration
    assert "to fleet_backend" in migration
    assert "face_image" not in migration
    assert "face_embedding" not in migration
    assert "Face re-registration requests" in dashboard
    assert 'data-face-decision="approve"' in dashboard
    assert 'data-face-decision="reject"' in dashboard
    assert "window.confirm" in dashboard
