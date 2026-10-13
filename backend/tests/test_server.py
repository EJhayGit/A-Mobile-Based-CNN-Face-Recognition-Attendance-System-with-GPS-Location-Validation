from __future__ import annotations

from dataclasses import replace
from pathlib import Path

from fastapi.testclient import TestClient

from backend.main import create_app
from backend.services import bootstrap_manager
from backend.tests.conftest import create_driver, csrf, manager_login


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
    assert "/assets/styles.css?v=20260825-responsive-sidebar" in page.text
    assert "/assets/login.js?v=20260814-agila" in page.text
    assert "/assets/theme.js?v=20260814-release" in page.text
    assert "<script>" not in page.text
    logo = client.get("/assets/agila-logo.png")
    assert logo.status_code == 200
    assert logo.headers["content-type"] == "image/png"
    font = client.get("/assets/Montserrat-VariableFont_wght.ttf")
    assert font.status_code == 200
    assert len(font.content) == 744936
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
    assert (
        "/assets/app.js?v=20260911-device-authorization-responsive-sidebar"
        in index_source
    )
    assert "/assets/styles.css?v=20260911-security-spacing" in index_source
    assert "/assets/app.js?v=20260814-agila" not in index_source
    assert "deliveryQuery.set('page_size', '10')" in app_source
    assert "${siteLocationsSection}${siteAssignmentHistorySection}" in app_source
    assert app_source.index("const siteLocationsSection") < app_source.index(
        "const siteAssignmentHistorySection"
    )
    assert ".delivery-table').before(" not in app_source
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
    assert "data-delete-driver-list" in app_source
    assert "async function deleteDriver(driverId, driver, button)" in app_source
    assert "button.disabled = true" in app_source
    assert "deleteDriver(id, driver, button)" in app_source
    assert app_source.count('href="/drivers/${driver.id}"') == 2
    assert "confirmDriverDeletion(driver)" in app_source
    assert "input.value !== driver.full_name" in app_source
    assert "confirm.disabled = true" in app_source
    assert "Permanent account action" in app_source
    assert (
        "Attendance, Site Assignment, and audit history will be preserved" in app_source
    )
    assert "data-delete-location" in app_source
    assert "Type ${location.name} to confirm" in app_source
    assert "Attendance and Site Assignment history will be preserved" in app_source
    assert app_source.count("Cancel any active Site Assignment first") == 2
    assert "data-cancel-route" in app_source
    assert "The route will remain in history" in app_source
    assert 'id="route-stop-list"' in app_source
    assert 'id="add-route-stop"' in app_source
    assert "data-move-stop" in app_source
    assert "data-remove-stop" in app_source
    assert "data-edit-stops" in app_source
    assert "function routeTimeline(assignment" in app_source
    assert "completed_stop_count" in app_source
    assert "/stops`, { method: 'PUT'" in app_source
    assert "Save Stop Order" in app_source
    assert "['in_progress', 'completed']" not in app_source
    assert ".route-progress" in styles
    assert ".route-stop-editor" in styles
    assert "function pagination(data, pageParameter = 'page')" in app_source
    assert "Showing ${start.toLocaleString()}–${end.toLocaleString()}" in app_source
    assert "? [1, 2, 3, totalPages]" in app_source
    assert "'Next page'" in app_source
    assert "'Last page'" in app_source
    assert "pageLink(page - 1, 'Previous'" not in app_source
    assert "pageLink(page + 1, '&gt;'" in app_source
    assert "pageLink(totalPages, '&gt;&gt;'" in app_source
    assert ".pagination-summary" in styles
    assert 'font-family: "Montserrat"' in styles
    assert "/assets/Montserrat-VariableFont_wght.ttf" in styles
    assert "Field Personnel Management" in app_source
    assert "Site Assignment History" in app_source
    assert "Site Location" in app_source


def test_responsive_sidebar_assets_are_present() -> None:
    index_source = Path("dashboard/index.html").read_text(encoding="utf-8")
    app_source = Path("dashboard/app.js").read_text(encoding="utf-8")
    styles = Path("dashboard/styles.css").read_text(encoding="utf-8")

    assert 'id="mobile-menu-toggle"' in index_source
    assert 'aria-controls="primary-sidebar"' in index_source
    assert 'id="primary-sidebar"' in index_source
    assert 'id="mobile-menu-close"' in index_source
    assert 'id="sidebar-backdrop"' in index_source
    assert "let isMobileMenuOpen = false" in app_source
    assert "function setMobileMenuOpen(isOpen, restoreFocus = false)" in app_source
    assert "sidebarBackdrop.addEventListener('click'" in app_source
    assert "event.key === 'Escape' && isMobileMenuOpen" in app_source
    assert "mobileNavigationQuery.addEventListener('change'" in app_source
    assert "@media (max-width: 1024px)" in styles
    assert "window.matchMedia('(max-width: 1024px)')" in app_source
    assert ".sidebar.is-open { transform: translateX(0); }" in styles
    assert "#app { margin-left: 0; padding: 4.75rem 1.25rem 3rem; }" in styles
    assert ".sidebar { width: 76px" not in styles
    sidebar_rule = styles[styles.index(".sidebar {") : styles.index(".brand {")]
    backdrop_rule = styles[
        styles.index("  .sidebar-backdrop {") : styles.index(
            "  #app { margin-left: 0;"
        )
    ]
    assert "position: fixed;" in sidebar_rule
    assert "z-index: 10001;" in sidebar_rule
    assert "z-index: 10000;" in backdrop_rule
    assert "z-index: 9999;" in styles[styles.index("  .mobile-menu-toggle {") :]


def test_admin_pagination_combines_search_filter_sort_and_bounded_loading(
    client: TestClient,
) -> None:
    manager_login(client)
    for index in range(25):
        response = client.post(
            "/api/manager/drivers",
            headers=csrf(client),
            json={
                "employee_id": f"FP-{index:03d}",
                "full_name": f"Field Person {24 - index:03d}",
            },
        )
        assert response.status_code == 201

    first = client.get(
        "/api/manager/drivers?status=pending_activation&sort=id_asc"
    ).json()
    assert first["count"] == 25
    assert first["page"] == 1
    assert first["page_size"] == 20
    assert first["total_pages"] == 2
    assert len(first["drivers"]) == 20
    assert [item["employee_id"] for item in first["drivers"]] == [
        f"FP-{index:03d}" for index in range(20)
    ]

    second = client.get(
        "/api/manager/drivers?status=pending_activation&sort=id_asc&page=2"
    ).json()
    assert len(second["drivers"]) == 5
    assert second["drivers"][0]["employee_id"] == "FP-020"

    searched = client.get(
        "/api/manager/drivers?search=FP-00&status=pending_activation"
        "&sort=name_desc&page_size=4&page=2"
    ).json()
    assert searched["count"] == 10
    assert len(searched["drivers"]) == 4
    names = [item["full_name"] for item in searched["drivers"]]
    assert names == sorted(names, reverse=True)

    for index in range(23):
        response = client.post(
            "/api/manager/locations",
            headers=csrf(client),
            json={
                "name": f"Site {index:03d}",
                "latitude": 14.5,
                "longitude": 121.0,
                "radius_meters": 100,
            },
        )
        assert response.status_code == 201
    locations = client.get("/api/manager/locations?sort=name_asc&page=2").json()
    assert locations["count"] == 23
    assert len(locations["locations"]) == 3
    assert locations["locations"][0]["name"] == "Site 020"


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
