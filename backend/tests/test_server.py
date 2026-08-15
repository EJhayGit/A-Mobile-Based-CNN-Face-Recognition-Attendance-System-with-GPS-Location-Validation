from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from fastapi.testclient import TestClient

from backend.main import create_app
from backend.services import bootstrap_manager
from backend.tests.conftest import create_driver


def test_health_and_login_page_render(client: TestClient) -> None:
    health = client.get("/health")
    assert health.json() == {"status": "ok"}
    assert health.headers["cache-control"] == "no-store"
    assert health.headers["x-content-type-options"] == "nosniff"
    assert health.headers["x-frame-options"] == "DENY"
    assert health.headers["referrer-policy"] == "strict-origin-when-cross-origin"
    page = client.get("/login")
    assert page.status_code == 200
    assert page.headers["cache-control"] == "no-store"
    assert "AGILA Fleet Manager" in page.text
    assert "signup" not in page.text.lower()
    assert '<form id="login-form" method="post" action="/login">' in page.text
    assert "/assets/styles.css?v=20260814-agila" in page.text
    assert "/assets/login.js?v=20260814-agila" in page.text
    assert "/assets/theme.js?v=20260814-release" in page.text
    assert "<script>" not in page.text
    logo = client.get("/assets/agila-logo.png")
    assert logo.status_code == 200
    assert logo.headers["content-type"] == "image/png"
    theme = client.get("/assets/theme.js?v=20260814-release")
    assert theme.status_code == 200
    assert "fleet-theme" in theme.text


def test_validation_errors_do_not_reflect_submitted_secret(client: TestClient) -> None:
    response = client.post(
        "/api/manager/auth/login", json={"password": "Submitted-Secret-Value"}
    )
    assert response.status_code == 422
    assert response.json()["detail"] == "Invalid request"
    assert "Submitted-Secret-Value" not in response.text


def test_sensitive_authentication_failures_are_rate_limited(settings, factory) -> None:
    with factory() as db:
        bootstrap_manager(db, "manager_test", "Manager-Test-Password-1!")
    limited_settings = replace(settings, auth_rate_limit_attempts=2)
    with TestClient(create_app(limited_settings, factory)) as limited:
        for _ in range(2):
            response = limited.post(
                "/api/manager/auth/login",
                json={"login_id": "manager_test", "password": "wrong-password"},
            )
            assert response.status_code == 401
        blocked = limited.post(
            "/api/manager/auth/login",
            json={"login_id": "manager_test", "password": "wrong-password"},
        )
        assert blocked.status_code == 429
        assert blocked.json()["detail"] == "Too many attempts. Try again later."
        assert blocked.headers["retry-after"] == str(
            limited_settings.auth_rate_limit_window_seconds
        )


def test_cors_is_absent_by_default_and_explicit_when_configured(
    settings, factory
) -> None:
    origin = "https://fleet.example.test"
    with TestClient(create_app(settings, factory)) as same_origin:
        assert "access-control-allow-origin" not in same_origin.get("/health").headers
    cors_settings = replace(settings, cors_allowed_origins=(origin,))
    with TestClient(create_app(cors_settings, factory)) as cors_client:
        response = cors_client.options(
            "/api/manager/me",
            headers={
                "Origin": origin,
                "Access-Control-Request-Method": "GET",
            },
        )
        assert response.status_code == 200
        assert response.headers["access-control-allow-origin"] == origin
        assert response.headers["access-control-allow-credentials"] == "true"


def test_production_headers_hosts_and_api_docs_are_fail_closed(
    settings, factory
) -> None:
    production = replace(
        settings,
        environment="production",
        cookie_secure=True,
        allowed_hosts=("testserver",),
        enable_api_docs=False,
    )
    with TestClient(create_app(production, factory)) as production_client:
        health = production_client.get("/health")
        assert health.status_code == 200
        assert health.headers["strict-transport-security"].startswith("max-age=")
        assert "frame-ancestors 'none'" in health.headers["content-security-policy"]
        assert production_client.get("/docs").status_code == 404
        rejected = production_client.get(
            "/health", headers={"Host": "untrusted.example.test"}
        )
        assert rejected.status_code == 400


def test_oversized_request_is_rejected_before_parsing(settings, factory) -> None:
    limited_settings = replace(settings, max_request_bytes=1024)
    with TestClient(create_app(limited_settings, factory)) as limited:
        response = limited.post(
            "/api/manager/auth/login",
            content=b"x" * 1025,
            headers={"Content-Type": "application/json"},
        )
        assert response.status_code == 413
        assert response.json()["detail"] == "Request too large"


def test_manager_listing_is_protected_and_authenticated(client: TestClient) -> None:
    anonymous = TestClient(client.app)
    assert anonymous.get("/api/manager/attendance").status_code == 401
    created = create_driver(client)
    response = client.get("/api/manager/drivers")
    assert response.status_code == 200
    assert response.json()["drivers"][0]["id"] == created["driver"]["id"]


def test_delivery_location_picker_assets_are_present() -> None:
    index_source = Path("dashboard/index.html").read_text(encoding="utf-8")
    app_source = Path("dashboard/app.js").read_text(encoding="utf-8")
    styles = Path("dashboard/styles.css").read_text(encoding="utf-8")
    assert "/assets/app.js?v=20260814-driver-actions" in index_source
    assert "/assets/app.js?v=20260814-agila" not in index_source
    assert 'id="location-picker-map"' in app_source
    assert "pickerMap.on('click'" in app_source
    assert "draggable: true" in app_source
    assert "pickerMarker.on('dragend'" in app_source
    assert "pickerRadius.setRadius" in app_source
    assert 'name="radius_meters"' in app_source
    assert "L.circle([lat, lng]" in app_source
    assert "setPickerPosition(location.latitude, location.longitude)" in app_source
    assert ".location-picker-map" in styles
    assert ".dropoff-pin" in styles
    assert ".geofence-legend" in styles
    assert "Generate / Reset Activation Code" in app_source
    assert "<th>Action</th>" in app_source
    assert 'data-driver-status="${action}"' in app_source
    assert (
        "const label = action === 'reactivate' ? 'Reactivate' : 'Disable'" in app_source
    )
    assert "/${button.dataset.driverId}/${action}" in app_source
    assert (
        "Their active sessions and unused activation codes will be revoked"
        in app_source
    )
    assert "navigator.clipboard?.writeText" in app_source
    assert "document.execCommand('copy')" in app_source
    assert "data-delete-driver" in app_source
    assert "Type ${driver.full_name} to confirm" in app_source
    assert "Attendance, route, and audit history will be preserved" in app_source
    assert "data-delete-location" in app_source
    assert "Type ${location.name} to confirm" in app_source
    assert "Attendance and route history will be preserved" in app_source
    assert app_source.count("Cancel any active route first") == 2
    assert "data-cancel-route" in app_source
    assert "The route will remain in history" in app_source


def test_map_tile_origin_is_allowed_by_content_security_policy(
    client: TestClient,
) -> None:
    tile_origin = "https://tile.openstreetmap.org"
    app_source = Path("dashboard/app.js").read_text(encoding="utf-8")
    assert app_source.count(f"{tile_origin}/{{z}}/{{x}}/{{y}}.png") == 2

    response = client.get("/login")
    directives = response.headers["content-security-policy"].split(";")
    image_sources = next(
        directive.split()[1:]
        for directive in directives
        if directive.strip().startswith("img-src ")
    )
    assert tile_origin in image_sources
