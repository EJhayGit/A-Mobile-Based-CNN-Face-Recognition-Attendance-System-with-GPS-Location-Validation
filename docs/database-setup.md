# Database setup

The browser and phone communicate with FastAPI; neither uses the Supabase Data
API. FastAPI connects through SQLAlchemy/psycopg with a separately provisioned
PostgreSQL login granted membership in the credential-free `fleet_backend` group.
Keep that login's connection string only in the backend runtime environment.

## Fresh development database

Use an empty disposable Supabase/PostgreSQL development database. Review every
SQL file under `supabase/migrations/` in chronological filename order. The chain
expects Supabase roles (`anon`, `authenticated`, `service_role`) and includes
`20260809065310_full_application_schema_reset.sql`, which drops application and
legacy tables. Do not run this chain against existing data. Ordinary PostgreSQL
installations require an administrator to review the Supabase role assumptions.

Apply the reviewed files with an administrative migration connection. The final
schema includes multi-stop assignments, face re-registration approval, and device
authorization/replacement; deploying only the older schema is incompatible with
the current API. RLS and least-privilege backend grants are part of the migrations.
Provision the application login separately and grant `fleet_backend` membership;
do not store an administrator's connection in the application.

For an existing installation, inspect its actual schema and migration history
and prepare a backed-up, separately reviewed upgrade plan. This repository does
not execute any database operation or establish another installation's migration
state. Never use the full reset chain as an upgrade procedure.

After database setup, inject `backend/.env.example` values with real private
credentials, bootstrap a manager, and run the server as described in the README.
