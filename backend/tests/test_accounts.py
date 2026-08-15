from __future__ import annotations

from datetime import timedelta

from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from backend.models import (
    Account,
    AccountAuditLog,
    ActivationCode,
    AuthSession,
    DriverProfile,
    utcnow,
)
from backend.services import AppError, bootstrap_manager
from backend.tests.conftest import activate_driver, create_driver, csrf, manager_login


def test_bootstrap_is_hashed_audited_and_duplicate_safe(
    factory: sessionmaker[Session],
) -> None:
    with factory() as db:
        manager = bootstrap_manager(db, "manager_test", "Manager-Test-Password-1!")
        assert manager.password_hash != "Manager-Test-Password-1!"
        assert manager.password_hash.startswith("$argon2id$")
        event = db.scalar(select(AccountAuditLog))
        assert event.event_type == "manager_bootstrap"
        assert "password" not in str(event.safe_metadata).lower()
        try:
            bootstrap_manager(db, "second_manager", "Manager-Test-Password-2!")
        except AppError as error:
            assert error.status_code == 409
        else:
            raise AssertionError("duplicate manager bootstrap should fail")


def test_manager_login_generic_failure_and_logout_revocation(
    client: TestClient, factory
):
    for login_id, password in [
        ("manager_test", "wrong-password"),
        ("missing_manager", "wrong-password"),
    ]:
        response = client.post(
            "/api/manager/auth/login", json={"login_id": login_id, "password": password}
        )
        assert response.status_code == 401
        assert response.json()["detail"] == "Invalid login credentials"
    manager_login(client)
    with factory() as db:
        session_id = db.scalar(
            select(AuthSession.id).where(AuthSession.revoked_at.is_(None))
        )
    response = client.post("/api/manager/auth/logout", headers=csrf(client))
    assert response.status_code == 200
    with factory() as db:
        assert db.get(AuthSession, session_id).revoked_at is not None
    assert client.get("/api/manager/me").status_code == 401


def test_csrf_required_for_cookie_mutations(client: TestClient):
    manager_login(client)
    response = client.post(
        "/api/manager/drivers",
        json={"employee_id": "TEST-DRV-CSRF", "full_name": "Test Driver CSRF"},
    )
    assert response.status_code == 403
    assert response.json()["detail"] == "Invalid CSRF token"


def test_driver_creation_unique_and_code_only_hashed(client: TestClient, factory):
    created = create_driver(client)
    assert created["driver"]["status"] == "pending_activation"
    assert created["activation_code"]
    with factory() as db:
        code = db.scalar(select(ActivationCode))
        assert code.code_hash.startswith("$argon2id$")
        assert created["activation_code"] not in code.code_hash
        account = db.scalar(select(Account).where(Account.login_id == "TEST-DRV-001"))
        assert account.password_hash is None
    duplicate = client.post(
        "/api/manager/drivers",
        headers=csrf(client),
        json={"employee_id": "TEST-DRV-001", "full_name": "Duplicate"},
    )
    assert duplicate.status_code == 409
    assert (
        "activation_code"
        not in client.get(f"/api/manager/drivers/{created['driver']['id']}").text
    )


def test_driver_soft_delete_preserves_identity_code_and_audit_history(
    client: TestClient, factory
):
    created = create_driver(client, "TEST-DRV-DELETE")
    driver_id = created["driver"]["id"]
    assert client.delete(f"/api/manager/drivers/{driver_id}").status_code == 403
    deleted = client.delete(f"/api/manager/drivers/{driver_id}", headers=csrf(client))
    assert deleted.status_code == 200
    assert deleted.json() == {"deleted": True}
    assert client.get(f"/api/manager/drivers/{driver_id}").status_code == 404
    assert client.get("/api/manager/drivers").json()["count"] == 0
    with factory() as db:
        account = db.get(Account, driver_id)
        assert account is not None
        assert account.status == "disabled"
        assert account.disabled_at is not None
        assert account.deleted_at is not None
        assert db.get(DriverProfile, driver_id) is not None
        assert (
            db.scalar(
                select(func.count(ActivationCode.id)).where(
                    ActivationCode.driver_account_id == driver_id
                )
            )
            == 1
        )
        code = db.scalar(
            select(ActivationCode).where(
                ActivationCode.driver_account_id == driver_id
            )
        )
        assert code.invalidated_at is not None
        assert db.scalar(
            select(func.count(AccountAuditLog.id)).where(
                AccountAuditLog.target_account_id == driver_id,
                AccountAuditLog.event_type == "driver_deleted",
            )
        ) == 1


def test_activation_reuse_regeneration_expiry_disable_and_attempt_limit(
    client: TestClient, factory
):
    created = create_driver(client)
    driver_id = created["driver"]["id"]
    regenerated = client.post(
        f"/api/manager/drivers/{driver_id}/activation-code", headers=csrf(client)
    ).json()
    old = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "TEST-DRV-001",
            "activation_code": created["activation_code"],
            "password": "Driver-Test-Password-1!",
        },
    )
    assert old.status_code == 400
    activated = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "TEST-DRV-001",
            "activation_code": regenerated["activation_code"],
            "password": "Driver-Test-Password-1!",
        },
    )
    assert activated.status_code == 200
    reused = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "TEST-DRV-001",
            "activation_code": regenerated["activation_code"],
            "password": "Driver-Test-Password-1!",
        },
    )
    assert reused.status_code == 400

    second = create_driver(client, "TEST-DRV-002")
    second_id = second["driver"]["id"]
    with factory() as db:
        current = db.scalar(
            select(ActivationCode)
            .where(ActivationCode.driver_account_id == second_id)
            .order_by(ActivationCode.created_at.desc())
        )
        current.expires_at = utcnow() - timedelta(seconds=1)
        db.commit()
    expired = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "TEST-DRV-002",
            "activation_code": second["activation_code"],
            "password": "Driver-Test-Password-2!",
        },
    )
    assert expired.status_code == 400
    replacement = client.post(
        f"/api/manager/drivers/{second_id}/activation-code", headers=csrf(client)
    ).json()
    client.patch(f"/api/manager/drivers/{second_id}/disable", headers=csrf(client))
    disabled = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "TEST-DRV-002",
            "activation_code": replacement["activation_code"],
            "password": "Driver-Test-Password-2!",
        },
    )
    assert disabled.status_code == 400
    client.patch(f"/api/manager/drivers/{second_id}/reactivate", headers=csrf(client))
    with factory() as db:
        current = db.scalar(
            select(ActivationCode)
            .where(ActivationCode.driver_account_id == second_id)
            .order_by(ActivationCode.created_at.desc())
        )
        assert current.invalidated_at is not None
    invalidated = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "TEST-DRV-002",
            "activation_code": replacement["activation_code"],
            "password": "Driver-Test-Password-2!",
        },
    )
    assert invalidated.status_code == 400


def test_failed_activation_attempt_limit(client: TestClient, factory):
    created = create_driver(client)
    for _ in range(3):
        response = client.post(
            "/api/driver/activate",
            json={
                "employee_id": "TEST-DRV-001",
                "activation_code": "WRONG999",
                "password": "Driver-Test-Password-1!",
            },
        )
        assert response.status_code == 400
    valid_after_limit = client.post(
        "/api/driver/activate",
        json={
            "employee_id": "TEST-DRV-001",
            "activation_code": created["activation_code"],
            "password": "Driver-Test-Password-1!",
        },
    )
    assert valid_after_limit.status_code == 400
    with factory() as db:
        code = db.scalar(select(ActivationCode))
        assert code.failed_attempt_count == 3
        assert code.invalidated_at is not None


def test_driver_login_password_change_disable_reactivate_and_role_boundaries(
    client: TestClient,
):
    created = create_driver(client)
    tokens = activate_driver(client, created)
    bearer = {"Authorization": f"Bearer {tokens['access_token']}"}
    assert client.get("/api/driver/me", headers=bearer).status_code == 200
    assert client.get("/api/manager/drivers", headers=bearer).status_code == 403
    assert (
        client.post(
            "/attendance/sync",
            headers={**bearer, "Idempotency-Key": "not-used"},
            json={},
        ).status_code
        == 422
    )
    changed = client.post(
        "/api/driver/password",
        headers=bearer,
        json={
            "current_password": "Driver-Test-Password-1!",
            "new_password": "Driver-Test-Password-NEW!",
        },
    )
    assert changed.status_code == 200
    assert client.get("/api/driver/me", headers=bearer).status_code == 401
    assert (
        client.post(
            "/api/driver/auth/login",
            json={"login_id": "TEST-DRV-001", "password": "Driver-Test-Password-1!"},
        ).status_code
        == 401
    )
    new_login = client.post(
        "/api/driver/auth/login",
        json={"login_id": "TEST-DRV-001", "password": "Driver-Test-Password-NEW!"},
    )
    assert new_login.status_code == 200
    client.patch(
        f"/api/manager/drivers/{created['driver']['id']}/disable", headers=csrf(client)
    )
    assert (
        client.post(
            "/api/driver/auth/login",
            json={"login_id": "TEST-DRV-001", "password": "Driver-Test-Password-NEW!"},
        ).status_code
        == 401
    )
    client.patch(
        f"/api/manager/drivers/{created['driver']['id']}/reactivate",
        headers=csrf(client),
    )
    assert (
        client.post(
            "/api/driver/auth/login",
            json={"login_id": "TEST-DRV-001", "password": "Driver-Test-Password-NEW!"},
        ).status_code
        == 200
    )


def test_refresh_rotation_and_revoked_refresh_rejected(client: TestClient):
    tokens = activate_driver(client, create_driver(client))
    refreshed = client.post(
        "/api/driver/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
    )
    assert refreshed.status_code == 200
    assert (
        client.post(
            "/api/driver/auth/refresh", json={"refresh_token": tokens["refresh_token"]}
        ).status_code
        == 401
    )


def test_audit_metadata_contains_no_secrets(client: TestClient, factory):
    created = create_driver(client)
    activate_driver(client, created)
    with factory() as db:
        metadata = str(
            [item.safe_metadata for item in db.scalars(select(AccountAuditLog))]
        ).lower()
        assert "password" not in metadata
        assert created["activation_code"].lower() not in metadata
        assert "refresh_token" not in metadata
        assert db.scalar(select(func.count(AccountAuditLog.id))) >= 4
