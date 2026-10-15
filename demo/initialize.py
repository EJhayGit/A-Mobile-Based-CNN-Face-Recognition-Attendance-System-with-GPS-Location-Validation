"""Initialize the bundled local demo database without touching remote hosts."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path

EXPECTED_MIGRATIONS = {
    "20260809064225_backend_manager_portal.sql": "df8029d62416be5ec5f4ceab37cc4abf0f00851259520f1321b41ed589b3752b",
    "20260809065310_full_application_schema_reset.sql": "144dc78c4dfef414208bdd0586623bc3baa07edc1e03b280afe101bceea8cca6",
    "20260810163738_delivery_dashboard.sql": "a51d285c49b4caaae94ef87c84ae9dfdab4c662c6c74cb2197143b76dd1a6610",
    "20260811030309_configurable_delivery_geofence.sql": "76c83e842920e0df3c795ea7b2232db4da02f79ee7c3045bb293b853255f499e",
    "20260814044007_add_soft_delete_timestamps.sql": "18e974a4445c40d826a306d32406ab6f19449c8cc6bf82062e5b6b610b6546a8",
    "20260821090000_multi_dropoff_routes.sql": "a9dee7d71342136a12335a684c1899745b1440cced37b5de697534586272e75b",
    "20260823090000_face_reregistration_approval.sql": "2a606eaf55c9d4a61ebf0fe0c654dd202eb6248f23ef8ca7b375131f4844b4d3",
    "20260910090000_driver_device_authorization.sql": "4e4497e919ec17e244ae3435b02d48123d2d9f42e7c4f88f637c73a26fa1cb3f",
}


EXPECTED_INITIALIZATION_SHA256 = "7f4f52dfdca45b66eeb02009b90ec18109d440ff3fc6d198d58b142f57c85fe7"


def validate_initialization(path: Path) -> str:
    """Read and verify one SQL bundle before any database connection."""
    try:
        content = Path(path).read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    except OSError as error:
        raise RuntimeError(
            "Unable to read demo/init.sql; extract the complete repository to a short path"
        ) from error
    if hashlib.sha256(content).hexdigest() != EXPECTED_INITIALIZATION_SHA256:
        raise RuntimeError("Demo initialization SQL differs from the approved content")
    return content.decode("utf-8")


def migration_digest(migrations: dict[str, str]) -> str:
    payload = json.dumps(
        dict(sorted(migrations.items())), separators=(",", ":"), ensure_ascii=True
    ).encode("ascii")
    return hashlib.sha256(payload).hexdigest()


def validate_installation(
    marker: dict[str, str] | None,
    instance: str,
    digest: str,
    existing_tables: list[str],
) -> bool:
    if marker is None:
        if existing_tables:
            raise RuntimeError("Unmarked database contains existing public tables")
        return True
    if (
        marker.get("instance_id") != instance
        or marker.get("migration_digest") != digest
    ):
        raise RuntimeError("Database installation marker does not match this demo")
    return False


def _require_environment() -> tuple[str, str, str, str, str]:
    instance = os.getenv("DEMO_INSTANCE_ID", "")
    admin_password = os.getenv("DEMO_DB_ADMIN_PASSWORD", "")
    app_password = os.getenv("DEMO_DB_APP_PASSWORD", "")
    jwt_secret = os.getenv("DEMO_JWT_SECRET", "")
    manager_password = os.getenv("DEMO_MANAGER_PASSWORD", "")
    if not re.fullmatch(r"[0-9a-f]{32}", instance):
        raise RuntimeError("Demo instance configuration is invalid")
    for value, size in (
        (admin_password, 64),
        (app_password, 64),
        (jwt_secret, 96),
        (manager_password, 40),
    ):
        if not re.fullmatch(rf"[0-9a-f]{{{size}}}", value):
            raise RuntimeError("Demo credential configuration is invalid")
    return instance, admin_password, app_password, jwt_secret, manager_password


def initialize(initialization_file: Path = Path("/demo/init.sql")) -> None:
    # Imports are runtime-only so host-side guard tests need only the standard library.
    instance, admin_password, app_password, _jwt_secret, manager_password = (
        _require_environment()
    )
    initialization_sql = validate_initialization(initialization_file)
    # Preserve the original eight-migration identity for existing demo restarts.
    digest = migration_digest(EXPECTED_MIGRATIONS)

    import psycopg
    from psycopg import sql
    from sqlalchemy import create_engine
    from sqlalchemy.engine import URL
    from sqlalchemy.orm import sessionmaker

    from backend.models import Account
    from backend.services import AppError, bootstrap_manager

    with (
        psycopg.connect(
            host="database",
            port=5432,
            dbname="agila_demo",
            user="postgres",
            password=admin_password,
        ) as connection,
        connection.cursor() as cursor,
    ):
        cursor.execute("SELECT pg_advisory_xact_lock(741902184)")
        cursor.execute("SELECT to_regclass('agila_demo_setup.installation')")
        has_marker_table = cursor.fetchone()[0] is not None
        marker = None
        if has_marker_table:
            cursor.execute(
                "SELECT instance_id, migration_digest FROM agila_demo_setup.installation WHERE singleton = true"
            )
            row = cursor.fetchone()
            if row:
                marker = {"instance_id": row[0], "migration_digest": row[1]}
        cursor.execute("""SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
            WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
            UNION SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
            WHERE n.nspname='public' AND NOT EXISTS (
                SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass
                AND d.objid=p.oid AND d.deptype='e')""")
        tables = [row[0] for row in cursor.fetchall()]
        is_new = validate_installation(marker, instance, digest, tables)
        if is_new:
            cursor.execute(initialization_sql)
            cursor.execute("CREATE SCHEMA agila_demo_setup")
            cursor.execute(
                "CREATE TABLE agila_demo_setup.installation (singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton), instance_id text NOT NULL, migration_digest text NOT NULL, state text NOT NULL CHECK (state = 'schema-ready'))"
            )
            cursor.execute(
                "CREATE ROLE agila_demo_app LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD "
                + sql.Literal(app_password).as_string(connection)
            )
            cursor.execute("GRANT fleet_backend TO agila_demo_app")
            cursor.execute(
                "INSERT INTO agila_demo_setup.installation (singleton, instance_id, migration_digest, state) VALUES (true, %s, %s, 'schema-ready')",
                (instance, digest),
            )

    app_url = URL.create(
        "postgresql+psycopg",
        username="agila_demo_app",
        password=app_password,
        host="database",
        port=5432,
        database="agila_demo",
    )
    engine = create_engine(app_url, pool_pre_ping=True)
    try:
        factory = sessionmaker(engine, expire_on_commit=False)
        with factory() as session:
            if (
                session.query(Account.id)
                .filter(Account.role == "fleet_manager")
                .first()
                is None
            ):
                try:
                    bootstrap_manager(session, "demo_manager", manager_password)
                except AppError as error:
                    if error.status_code != 409:
                        raise
    finally:
        engine.dispose()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--init-sql", default="/demo/init.sql")
    args = parser.parse_args()
    try:
        initialize(Path(args.init_sql))
    except RuntimeError as error:
        print(f"Demo setup stopped: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - avoid leaking credentials through dependency error messages.
        print(
            "Demo initialization failed; verify the local demo configuration and bundled database.",
            file=sys.stderr,
        )
        return 1
    print("Local demo database ready.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
