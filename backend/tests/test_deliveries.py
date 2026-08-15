from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import func, select

from backend.main import create_app
from backend.models import Account, AuthSession, DeliveryAssignment, DeliveryLocation
from backend.tests.conftest import activate_driver, create_driver, csrf, manager_login


def create_location(
    client: TestClient, name: str = "North Distribution Hub", radius: int = 100
) -> dict:
    manager_login(client)
    response = client.post(
        "/api/manager/locations",
        headers=csrf(client),
        json={
            "name": name,
            "address": "Quezon City, Metro Manila",
            "latitude": 14.6760,
            "longitude": 121.0437,
            "radius_meters": radius,
        },
    )
    assert response.status_code == 201
    return response.json()["location"]


def active_driver(client: TestClient, employee_id: str = "TEST-DRV-DELIVERY") -> dict:
    created = create_driver(client, employee_id)
    activate_driver(client, created)
    return created["driver"]


def create_assignment(client: TestClient, driver: dict, location: dict) -> dict:
    response = client.post(
        "/api/manager/deliveries",
        headers=csrf(client),
        json={
            "driver_id": driver["id"],
            "delivery_location_id": location["id"],
            "notes": "Synthetic thesis demo delivery",
        },
    )
    assert response.status_code == 201
    return response.json()["assignment"]


def test_create_edit_list_location_and_invalid_coordinates(client: TestClient):
    manager_login(client)
    invalid = client.post(
        "/api/manager/locations",
        headers=csrf(client),
        json={"name": "Invalid", "latitude": 91, "longitude": 121},
    )
    assert invalid.status_code == 422
    invalid_radius = client.post(
        "/api/manager/locations",
        headers=csrf(client),
        json={
            "name": "Invalid radius",
            "latitude": 14,
            "longitude": 121,
            "radius_meters": 9,
        },
    )
    assert invalid_radius.status_code == 422
    location = create_location(client, radius=350)
    assert location["radius_meters"] == 350
    edited = client.patch(
        f"/api/manager/locations/{location['id']}",
        headers=csrf(client),
        json={"name": "North Hub Updated", "radius_meters": 750, "active": False},
    )
    assert edited.status_code == 200
    assert edited.json()["location"]["active"] is False
    assert edited.json()["location"]["radius_meters"] == 750
    listing = client.get("/api/manager/locations")
    assert listing.json()["count"] == 1
    assert listing.json()["locations"][0]["name"] == "North Hub Updated"


def test_active_assignment_listing_detail_and_driver_integration(client: TestClient):
    location = create_location(client)
    created = create_driver(client, "TEST-DRV-DELIVERY-ME")
    tokens = activate_driver(client, created)
    driver = created["driver"]
    assignment = create_assignment(client, driver, location)
    assert assignment["status"] == "assigned"
    assert assignment["location"]["id"] == location["id"]
    listing = client.get("/api/manager/deliveries?status=assigned")
    assert listing.status_code == 200
    assert listing.json()["assignments"][0]["driver_id"] == driver["id"]
    detail = client.get(f"/api/manager/deliveries/{assignment['id']}")
    assert detail.json()["assignment"]["employee_id"] == driver["employee_id"]
    driver_detail = client.get(f"/api/manager/drivers/{driver['id']}").json()
    assert driver_detail["driver"]["current_assignment"]["id"] == assignment["id"]
    driver_me = client.get(
        "/api/driver/me",
        headers={"Authorization": f"Bearer {tokens['access_token']}"},
    )
    assert driver_me.status_code == 200
    assert (
        driver_me.json()["driver"]["current_assignment"]["location"]["radius_meters"]
        == 100
    )


def test_disabled_location_and_disabled_driver_assignment_rejected(
    client: TestClient,
):
    location = create_location(client)
    driver = active_driver(client)
    client.patch(
        f"/api/manager/locations/{location['id']}",
        headers=csrf(client),
        json={"active": False},
    )
    disabled_location = client.post(
        "/api/manager/deliveries",
        headers=csrf(client),
        json={"driver_id": driver["id"], "delivery_location_id": location["id"]},
    )
    assert disabled_location.status_code == 409
    second_location = create_location(client, "South Hub")
    client.patch(f"/api/manager/drivers/{driver['id']}/disable", headers=csrf(client))
    disabled_driver = client.post(
        "/api/manager/deliveries",
        headers=csrf(client),
        json={
            "driver_id": driver["id"],
            "delivery_location_id": second_location["id"],
        },
    )
    assert disabled_driver.status_code == 409


def test_one_active_assignment_status_transitions_and_summary(client: TestClient):
    location = create_location(client)
    driver = active_driver(client)
    assignment = create_assignment(client, driver, location)
    duplicate = client.post(
        "/api/manager/deliveries",
        headers=csrf(client),
        json={"driver_id": driver["id"], "delivery_location_id": location["id"]},
    )
    assert duplicate.status_code == 409
    progress = client.patch(
        f"/api/manager/deliveries/{assignment['id']}",
        headers=csrf(client),
        json={"status": "in_progress"},
    )
    assert progress.json()["assignment"]["status"] == "in_progress"
    completed = client.patch(
        f"/api/manager/deliveries/{assignment['id']}",
        headers=csrf(client),
        json={"status": "completed"},
    )
    assert completed.json()["assignment"]["completed_at"] is not None
    invalid = client.patch(
        f"/api/manager/deliveries/{assignment['id']}",
        headers=csrf(client),
        json={"status": "assigned"},
    )
    assert invalid.status_code == 409
    overview = client.get("/api/manager/overview").json()
    assert overview["completed_today"] == 1
    assert overview["in_progress_deliveries"] == 0


def test_cancelled_history_allows_new_assignment(client: TestClient):
    first = create_location(client)
    second = create_location(client, "Backup Hub")
    driver = active_driver(client)
    assignment = create_assignment(client, driver, first)
    cancelled = client.patch(
        f"/api/manager/deliveries/{assignment['id']}",
        headers=csrf(client),
        json={"status": "cancelled"},
    )
    assert cancelled.json()["assignment"]["status"] == "cancelled"
    replacement = create_assignment(client, driver, second)
    assert replacement["location"]["id"] == second["id"]
    assert client.get("/api/manager/deliveries").json()["count"] == 2


def test_driver_and_location_soft_delete_require_cancel_and_preserve_history(
    client: TestClient, factory
):
    location = create_location(client)
    driver = active_driver(client)
    assignment = create_assignment(client, driver, location)

    driver_active = client.delete(
        f"/api/manager/drivers/{driver['id']}", headers=csrf(client)
    )
    assert driver_active.status_code == 409
    assert "Cancel" in driver_active.json()["detail"]
    location_active = client.delete(
        f"/api/manager/locations/{location['id']}", headers=csrf(client)
    )
    assert location_active.status_code == 409
    assert "Cancel" in location_active.json()["detail"]

    cancelled = client.patch(
        f"/api/manager/deliveries/{assignment['id']}",
        headers=csrf(client),
        json={"status": "cancelled"},
    )
    assert cancelled.json()["assignment"]["status"] == "cancelled"

    driver_delete = client.delete(
        f"/api/manager/drivers/{driver['id']}", headers=csrf(client)
    )
    assert driver_delete.status_code == 200
    location_delete = client.delete(
        f"/api/manager/locations/{location['id']}", headers=csrf(client)
    )
    assert location_delete.status_code == 200
    assert client.get("/api/manager/drivers").json()["count"] == 0
    assert client.get("/api/manager/locations").json()["count"] == 0
    history = client.get(f"/api/manager/deliveries/{assignment['id']}")
    assert history.status_code == 200
    assert history.json()["assignment"]["status"] == "cancelled"
    with factory() as db:
        stored_driver = db.get(Account, driver["id"])
        stored_location = db.get(DeliveryLocation, location["id"])
        stored_assignment = db.get(DeliveryAssignment, assignment["id"])
        assert stored_driver is not None and stored_driver.deleted_at is not None
        assert stored_location is not None and stored_location.deleted_at is not None
        assert stored_assignment is not None
        assert db.scalar(
            select(func.count(AuthSession.id)).where(
                AuthSession.account_id == driver["id"],
                AuthSession.revoked_at.is_(None),
            )
        ) == 0


def test_unused_location_can_be_soft_deleted(client: TestClient, factory):
    location = create_location(client, "Temporary Hub")
    assert client.delete(f"/api/manager/locations/{location['id']}").status_code == 403
    deleted = client.delete(
        f"/api/manager/locations/{location['id']}", headers=csrf(client)
    )
    assert deleted.status_code == 200
    assert client.get("/api/manager/locations").json()["count"] == 0
    with factory() as db:
        stored = db.get(DeliveryLocation, location["id"])
        assert stored is not None
        assert stored.active is False
        assert stored.deleted_at is not None


def test_manager_only_csrf_and_database_persistence(
    client: TestClient, settings, factory
):
    anonymous = TestClient(client.app)
    assert anonymous.get("/api/manager/locations").status_code == 401
    manager_login(client)
    assert (
        client.post(
            "/api/manager/locations",
            json={"name": "No CSRF", "latitude": 14, "longitude": 121},
        ).status_code
        == 403
    )
    location = create_location(client)
    driver = active_driver(client)
    assignment = create_assignment(client, driver, location)
    with TestClient(create_app(settings, factory)) as restarted:
        login = restarted.post(
            "/api/manager/auth/login",
            json={
                "login_id": "manager_test",
                "password": "Manager-Test-Password-1!",
            },
        )
        assert login.status_code == 200
        persisted = restarted.get("/api/manager/deliveries").json()["assignments"]
        assert persisted[0]["id"] == assignment["id"]
    with factory() as db:
        assert db.scalar(select(func.count(DeliveryLocation.id))) == 1
        assert db.scalar(select(func.count(DeliveryAssignment.id))) == 1


def test_delivery_filters_and_migration_security(client: TestClient):
    location = create_location(client)
    driver = active_driver(client)
    create_assignment(client, driver, location)
    today = datetime.now(timezone.utc).date().isoformat()
    filtered = client.get(
        f"/api/manager/deliveries?driver_id={driver['id']}&date={today}"
    )
    assert filtered.status_code == 200
    assert filtered.json()["count"] == 1
    sql = (
        Path("supabase/migrations/20260810163738_delivery_dashboard.sql")
        .read_text(encoding="utf-8")
        .lower()
    )
    for required in (
        "delivery_assignments_one_active_driver_idx",
        "enable row level security",
        "revoke all on table public.delivery_assignments from anon",
        "delivery_assignments_backend_policy",
        "references public.accounts",
    ):
        assert required in sql
    geofence_sql = (
        Path("supabase/migrations/20260811030309_configurable_delivery_geofence.sql")
        .read_text(encoding="utf-8")
        .lower()
    )
    assert "add column radius_meters integer not null default 100" in geofence_sql
    assert "radius_meters between 10 and 5000" in geofence_sql
    soft_delete_sql = (
        Path("supabase/migrations/20260814044007_add_soft_delete_timestamps.sql")
        .read_text(encoding="utf-8")
        .lower()
    )
    assert soft_delete_sql.count("add column deleted_at timestamptz") == 2
    assert "accounts_current_driver_status_idx" in soft_delete_sql
    assert "delivery_locations_current_name_idx" in soft_delete_sql
    assert soft_delete_sql.count("where deleted_at is null") == 2
    assert "grant delete" not in soft_delete_sql
    assert "security definer" not in soft_delete_sql
    assert "drop " not in soft_delete_sql
