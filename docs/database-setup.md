# Database setup

The browser and phone communicate with FastAPI; neither uses the Supabase Data
API. FastAPI connects through SQLAlchemy/psycopg with a separately provisioned
PostgreSQL login granted membership in the credential-free `fleet_backend` group.
Keep that login's connection string only in the backend runtime environment.

## Fresh development database

Use an empty disposable Supabase/PostgreSQL development database. Review every
SQL file under `supabase/migrations/` in chronological filename order. The chain
conditionally revokes Supabase roles (`anon`, `authenticated`, `service_role`)
when present and includes the destructive
`20260809065310_full_application_schema_reset.sql`, which drops application and
legacy tables. Do not run this chain against existing data. The same eight-file
chain was also verified on fresh PostgreSQL 17 with
`pgcrypto` available. The database administrator must be able to create the
extension and credential-free group role; provider permissions may differ.

Apply **all eight files once**, in this order, to the empty application database:

1. `20260809064225_backend_manager_portal.sql`
2. `20260809065310_full_application_schema_reset.sql` (destructive reset)
3. `20260810163738_delivery_dashboard.sql`
4. `20260811030309_configurable_delivery_geofence.sql`
5. `20260814044007_add_soft_delete_timestamps.sql`
6. `20260821090000_multi_dropoff_routes.sql`
7. `20260823090000_face_reregistration_approval.sql`
8. `20260910090000_driver_device_authorization.sql`

On Supabase, use the project's SQL editor to run each reviewed file's contents
in order and stop on any error. Alternatively, with the PostgreSQL `psql` client
installed, run this PowerShell example from the repository root. Replace the
connection placeholders using your own provider's connection details. It
prompts for an administrator password without including it in the command:

```powershell
$migrationConnection = 'host=YOUR_DB_HOST port=5432 dbname=postgres user=YOUR_ADMIN_USER sslmode=require'
foreach ($migration in (Get-ChildItem supabase/migrations/*.sql | Sort-Object Name)) {
    psql $migrationConnection --password --set ON_ERROR_STOP=1 --single-transaction --file $migration.FullName
    if ($LASTEXITCODE -ne 0) { throw "Migration failed: $($migration.Name)" }
}
```

Use `sslmode=require` for Supabase/remote production connections. For a private
local PostgreSQL server without TLS, use its locally appropriate SSL setting;
the application must run in development mode. These are initialization commands,
not an existing-database upgrade procedure. Do not rerun the whole chain.

Apply the reviewed files with an administrative migration connection. The final
schema includes multi-stop assignments, face re-registration approval, and device
authorization/replacement; deploying only the older schema is incompatible with
the current API. RLS and least-privilege backend grants are part of the migrations.
Provision the application login separately and grant `fleet_backend` membership;
do not store an administrator's connection in the application.

For a fresh installation, an administrator can create a dedicated role with:

```sql
CREATE ROLE agila_app LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
GRANT fleet_backend TO agila_app;
```

Set its password privately: in an administrative `psql` session use
`\password agila_app` and follow the prompts. Do not paste a real password into
a saved SQL file. The application login must inherit `fleet_backend` membership;
the group itself is `NOLOGIN`. Put this login's SQLAlchemy/psycopg connection in
your private `DATABASE_URL`, using the `postgresql+psycopg://` scheme and
URL-encoding special characters in its password. On Supabase, consult the
[connection guide](https://supabase.com/docs/guides/database/connecting-to-postgres)
for a reachable direct or session-pooler endpoint and the appropriate custom-role
username; no project endpoint is supplied by this repository.

For an existing installation, inspect its actual schema and migration history
and prepare a backed-up, separately reviewed upgrade plan. This repository does
not execute any database operation or establish another installation's migration
state. Never use the full reset chain as an upgrade procedure.

After database setup, inject `backend/.env.example` values with real private
credentials, bootstrap a manager, and run the server as described in the README.
`/health` only runs `SELECT 1`;
it can pass even if migrations are missing. A usable installation should also
bootstrap the first manager, sign in at `/login`, and load the dashboard lists.
This fresh flow passed on 2026-10-14 with a restricted application login,
synthetic manager credentials, and eight authenticated API endpoints in
disposable local containers. Existing user databases were not accessed.
