-- Fresh demo initialization only; run through demo/initialize.py.

-- Source: 20260809064225_backend_manager_portal.sql
-- Bounded backend/Fleet Manager schema. FastAPI is the only application client.
-- Non-destructive: creates new tables and indexes; it does not alter old data.

-- Preserve the older, empty Supabase Auth/Data API schema and its migration
-- history, but quarantine direct API access so FastAPI remains the only
-- application boundary.
do $$
declare
  relation_name text;
  api_role text;
begin
  foreach relation_name in array array[
    'public.profiles',
    'public.drivers',
    'public.authorized_locations',
    'public.attendance_attempts'
  ]
  loop
    if to_regclass(relation_name) is not null then
      foreach api_role in array array['anon', 'authenticated', 'service_role']
      loop
        if exists (select 1 from pg_roles where rolname = api_role) then
          execute format(
            'revoke all privileges on table %s from %I',
            relation_name,
            api_role
          );
        end if;
      end loop;
    end if;
  end loop;

  if to_regprocedure('public.current_user_is_administrator()') is not null then
    revoke all privileges on function public.current_user_is_administrator()
      from public;
    foreach api_role in array array['anon', 'authenticated', 'service_role']
    loop
      if exists (select 1 from pg_roles where rolname = api_role) then
        execute format(
          'revoke all privileges on function public.current_user_is_administrator() from %I',
          api_role
        );
      end if;
    end loop;
  end if;
end $$;

create extension if not exists pgcrypto;

create table if not exists public.accounts (
  id text primary key default gen_random_uuid()::text,
  role text not null constraint accounts_role_check
    check (role in ('fleet_manager', 'driver')),
  login_id text not null constraint accounts_login_id_key unique,
  password_hash text,
  status text not null constraint accounts_status_check
    check (status in ('pending_activation', 'active', 'disabled')),
  password_changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  disabled_at timestamptz
);

create table if not exists public.driver_profiles (
  account_id text primary key references public.accounts(id) on delete cascade,
  employee_id text not null constraint driver_profiles_employee_id_key unique,
  full_name text not null,
  phone text,
  notes text,
  created_by_manager_id text not null references public.accounts(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists driver_profiles_created_by_manager_idx
  on public.driver_profiles (created_by_manager_id);
create index if not exists driver_profiles_full_name_idx
  on public.driver_profiles (lower(full_name));

create table if not exists public.activation_codes (
  id text primary key default gen_random_uuid()::text,
  driver_account_id text not null references public.accounts(id) on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  invalidated_at timestamptz,
  failed_attempt_count integer not null default 0
    constraint activation_attempts_check check (failed_attempt_count >= 0),
  created_by_manager_id text not null references public.accounts(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists activation_codes_current_idx
  on public.activation_codes (driver_account_id, expires_at);
create index if not exists activation_codes_created_by_manager_idx
  on public.activation_codes (created_by_manager_id);

create table if not exists public.auth_sessions (
  id text primary key default gen_random_uuid()::text,
  account_id text not null references public.accounts(id) on delete cascade,
  refresh_token_hash text not null constraint auth_sessions_refresh_hash_key unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  device_label text
);

create index if not exists auth_sessions_account_active_idx
  on public.auth_sessions (account_id, expires_at);

create table if not exists public.attendance_records (
  id text primary key default gen_random_uuid()::text,
  client_attempt_id text not null
    constraint attendance_client_attempt_id_key unique,
  driver_account_id text not null references public.accounts(id) on delete restrict,
  client_driver_id text not null,
  site_id text not null,
  captured_at_utc timestamptz not null,
  latitude double precision not null constraint attendance_latitude_check
    check (latitude between -90 and 90),
  longitude double precision not null constraint attendance_longitude_check
    check (longitude between -180 and 180),
  gps_accuracy_meters double precision not null constraint attendance_accuracy_check
    check (gps_accuracy_meters >= 0),
  distance_meters double precision not null constraint attendance_distance_check
    check (distance_meters >= 0),
  face_score double precision not null constraint attendance_face_score_check
    check (face_score between -1 and 1),
  face_verified boolean not null,
  gps_verified boolean not null,
  server_received_at timestamptz not null default now()
);

create index if not exists attendance_driver_captured_idx
  on public.attendance_records (driver_account_id, captured_at_utc desc);
create index if not exists attendance_captured_idx
  on public.attendance_records (captured_at_utc desc);

create table if not exists public.account_audit_logs (
  id text primary key default gen_random_uuid()::text,
  actor_account_id text references public.accounts(id) on delete set null,
  target_account_id text not null references public.accounts(id) on delete cascade,
  event_type text not null,
  safe_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists account_audit_actor_idx
  on public.account_audit_logs (actor_account_id);
create index if not exists account_audit_target_created_idx
  on public.account_audit_logs (target_account_id, created_at desc);

-- Credential-free group role. Create a separate LOGIN role out of band, grant
-- it this role, and keep that login/password only on the FastAPI host.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'fleet_backend') then
    create role fleet_backend nologin nosuperuser nocreatedb nocreaterole noinherit;
  end if;
end $$;

grant usage on schema public to fleet_backend;
grant select, insert, update on table public.accounts to fleet_backend;
grant select, insert, update on table public.driver_profiles to fleet_backend;
grant select, insert, update on table public.activation_codes to fleet_backend;
grant select, insert, update on table public.auth_sessions to fleet_backend;
grant select, insert, update on table public.attendance_records to fleet_backend;
grant select, insert, update on table public.account_audit_logs to fleet_backend;

-- The public schema is exposed by default on Supabase. No Data API client is
-- part of this system, so deny anon/authenticated and keep defense-in-depth RLS.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on table public.accounts from anon;
    revoke all on table public.driver_profiles from anon;
    revoke all on table public.activation_codes from anon;
    revoke all on table public.auth_sessions from anon;
    revoke all on table public.attendance_records from anon;
    revoke all on table public.account_audit_logs from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on table public.accounts from authenticated;
    revoke all on table public.driver_profiles from authenticated;
    revoke all on table public.activation_codes from authenticated;
    revoke all on table public.auth_sessions from authenticated;
    revoke all on table public.attendance_records from authenticated;
    revoke all on table public.account_audit_logs from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke all on table public.accounts from service_role;
    revoke all on table public.driver_profiles from service_role;
    revoke all on table public.activation_codes from service_role;
    revoke all on table public.auth_sessions from service_role;
    revoke all on table public.attendance_records from service_role;
    revoke all on table public.account_audit_logs from service_role;
  end if;
end $$;

alter table public.accounts enable row level security;
alter table public.driver_profiles enable row level security;
alter table public.activation_codes enable row level security;
alter table public.auth_sessions enable row level security;
alter table public.attendance_records enable row level security;
alter table public.account_audit_logs enable row level security;

create policy accounts_backend_policy on public.accounts
  for all to fleet_backend using (true) with check (true);
create policy driver_profiles_backend_policy on public.driver_profiles
  for all to fleet_backend using (true) with check (true);
create policy activation_codes_backend_policy on public.activation_codes
  for all to fleet_backend using (true) with check (true);
create policy auth_sessions_backend_policy on public.auth_sessions
  for all to fleet_backend using (true) with check (true);
create policy attendance_records_backend_policy on public.attendance_records
  for all to fleet_backend using (true) with check (true);
create policy account_audit_logs_backend_policy on public.account_audit_logs
  for all to fleet_backend using (true) with check (true);

-- Source: 20260809065310_full_application_schema_reset.sql
-- User-approved destructive reset of the development application's public
-- schema objects. Supabase-managed schemas, Auth/Storage data, platform roles,
-- extensions, and migration history are intentionally outside this boundary.

set lock_timeout = '5s';

-- Abort if another public relation appeared after the reviewed inventory.
do $$
declare
  unexpected_relations text;
begin
  select string_agg(c.relname, ', ' order by c.relname)
  into unexpected_relations
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p', 'v', 'm', 'S', 'f')
    and c.relname not in (
      'profiles',
      'drivers',
      'authorized_locations',
      'attendance_attempts',
      'accounts',
      'driver_profiles',
      'activation_codes',
      'auth_sessions',
      'attendance_records',
      'account_audit_logs'
    );

  if unexpected_relations is not null then
    raise exception 'application reset refused: unexpected public relations: %',
      unexpected_relations;
  end if;
end $$;

-- Drop only the ten reviewed application tables, in dependency order. This
-- permanently deletes their rows. No CASCADE is used.
drop table if exists public.account_audit_logs;
drop table if exists public.attendance_records;
drop table if exists public.auth_sessions;
drop table if exists public.activation_codes;
drop table if exists public.driver_profiles;
drop table if exists public.accounts;
drop table if exists public.attendance_attempts;
drop table if exists public.drivers;
drop table if exists public.authorized_locations;
drop table if exists public.profiles;

drop function if exists public.current_user_is_administrator();

create extension if not exists pgcrypto;

create table public.accounts (
  id text primary key default gen_random_uuid()::text,
  role text not null constraint accounts_role_check
    check (role in ('fleet_manager', 'driver')),
  login_id text not null constraint accounts_login_id_key unique,
  password_hash text,
  status text not null constraint accounts_status_check
    check (status in ('pending_activation', 'active', 'disabled')),
  password_changed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  disabled_at timestamptz
);

create table public.driver_profiles (
  account_id text primary key references public.accounts(id) on delete cascade,
  employee_id text not null constraint driver_profiles_employee_id_key unique,
  full_name text not null,
  phone text,
  notes text,
  created_by_manager_id text not null references public.accounts(id)
    on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index driver_profiles_created_by_manager_idx
  on public.driver_profiles (created_by_manager_id);
create index driver_profiles_full_name_idx
  on public.driver_profiles (lower(full_name));

create table public.activation_codes (
  id text primary key default gen_random_uuid()::text,
  driver_account_id text not null references public.accounts(id)
    on delete cascade,
  code_hash text not null,
  expires_at timestamptz not null,
  used_at timestamptz,
  invalidated_at timestamptz,
  failed_attempt_count integer not null default 0
    constraint activation_attempts_check check (failed_attempt_count >= 0),
  created_by_manager_id text not null references public.accounts(id)
    on delete restrict,
  created_at timestamptz not null default now()
);

create index activation_codes_current_idx
  on public.activation_codes (driver_account_id, expires_at);
create index activation_codes_created_by_manager_idx
  on public.activation_codes (created_by_manager_id);

create table public.auth_sessions (
  id text primary key default gen_random_uuid()::text,
  account_id text not null references public.accounts(id) on delete cascade,
  refresh_token_hash text not null constraint auth_sessions_refresh_hash_key
    unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  device_label text
);

create index auth_sessions_account_active_idx
  on public.auth_sessions (account_id, expires_at);

create table public.attendance_records (
  id text primary key default gen_random_uuid()::text,
  client_attempt_id text not null
    constraint attendance_client_attempt_id_key unique,
  driver_account_id text not null references public.accounts(id)
    on delete restrict,
  client_driver_id text not null,
  site_id text not null,
  captured_at_utc timestamptz not null,
  latitude double precision not null constraint attendance_latitude_check
    check (latitude between -90 and 90),
  longitude double precision not null constraint attendance_longitude_check
    check (longitude between -180 and 180),
  gps_accuracy_meters double precision not null
    constraint attendance_accuracy_check check (gps_accuracy_meters >= 0),
  distance_meters double precision not null
    constraint attendance_distance_check check (distance_meters >= 0),
  face_score double precision not null constraint attendance_face_score_check
    check (face_score between -1 and 1),
  face_verified boolean not null,
  gps_verified boolean not null,
  server_received_at timestamptz not null default now()
);

create index attendance_driver_captured_idx
  on public.attendance_records (driver_account_id, captured_at_utc desc);
create index attendance_captured_idx
  on public.attendance_records (captured_at_utc desc);

create table public.account_audit_logs (
  id text primary key default gen_random_uuid()::text,
  actor_account_id text references public.accounts(id) on delete set null,
  target_account_id text not null references public.accounts(id)
    on delete cascade,
  event_type text not null,
  safe_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index account_audit_actor_idx
  on public.account_audit_logs (actor_account_id);
create index account_audit_target_created_idx
  on public.account_audit_logs (target_account_id, created_at desc);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'fleet_backend') then
    create role fleet_backend nologin nosuperuser nocreatedb nocreaterole
      noinherit;
  end if;
end $$;

grant usage on schema public to fleet_backend;
grant select, insert, update on table public.accounts to fleet_backend;
grant select, insert, update on table public.driver_profiles to fleet_backend;
grant select, insert, update on table public.activation_codes to fleet_backend;
grant select, insert, update on table public.auth_sessions to fleet_backend;
grant select, insert, update on table public.attendance_records to fleet_backend;
grant select, insert, update on table public.account_audit_logs to fleet_backend;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on table public.accounts from anon;
    revoke all on table public.driver_profiles from anon;
    revoke all on table public.activation_codes from anon;
    revoke all on table public.auth_sessions from anon;
    revoke all on table public.attendance_records from anon;
    revoke all on table public.account_audit_logs from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on table public.accounts from authenticated;
    revoke all on table public.driver_profiles from authenticated;
    revoke all on table public.activation_codes from authenticated;
    revoke all on table public.auth_sessions from authenticated;
    revoke all on table public.attendance_records from authenticated;
    revoke all on table public.account_audit_logs from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke all on table public.accounts from service_role;
    revoke all on table public.driver_profiles from service_role;
    revoke all on table public.activation_codes from service_role;
    revoke all on table public.auth_sessions from service_role;
    revoke all on table public.attendance_records from service_role;
    revoke all on table public.account_audit_logs from service_role;
  end if;
end $$;

alter table public.accounts enable row level security;
alter table public.driver_profiles enable row level security;
alter table public.activation_codes enable row level security;
alter table public.auth_sessions enable row level security;
alter table public.attendance_records enable row level security;
alter table public.account_audit_logs enable row level security;

create policy accounts_backend_policy on public.accounts
  for all to fleet_backend using (true) with check (true);
create policy driver_profiles_backend_policy on public.driver_profiles
  for all to fleet_backend using (true) with check (true);
create policy activation_codes_backend_policy on public.activation_codes
  for all to fleet_backend using (true) with check (true);
create policy auth_sessions_backend_policy on public.auth_sessions
  for all to fleet_backend using (true) with check (true);
create policy attendance_records_backend_policy on public.attendance_records
  for all to fleet_backend using (true) with check (true);
create policy account_audit_logs_backend_policy on public.account_audit_logs
  for all to fleet_backend using (true) with check (true);

-- Source: 20260810163738_delivery_dashboard.sql
-- Minimum Fleet delivery destinations and assignments. FastAPI remains the
-- only application database boundary; Data API roles receive no access.

set lock_timeout = '5s';

create table public.delivery_locations (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  address text,
  latitude double precision not null
    constraint delivery_locations_latitude_check
    check (latitude between -90 and 90),
  longitude double precision not null
    constraint delivery_locations_longitude_check
    check (longitude between -180 and 180),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index delivery_locations_active_name_idx
  on public.delivery_locations (active, name);

create table public.delivery_assignments (
  id text primary key default gen_random_uuid()::text,
  driver_account_id text not null references public.accounts(id)
    on delete restrict,
  delivery_location_id text not null references public.delivery_locations(id)
    on delete restrict,
  assigned_by_manager_id text not null references public.accounts(id)
    on delete restrict,
  assigned_at timestamptz not null default now(),
  scheduled_at timestamptz,
  status text not null default 'assigned'
    constraint delivery_assignments_status_check
    check (status in ('assigned', 'in_progress', 'completed', 'cancelled')),
  notes text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index delivery_assignments_one_active_driver_idx
  on public.delivery_assignments (driver_account_id)
  where status in ('assigned', 'in_progress');
create index delivery_assignments_status_assigned_idx
  on public.delivery_assignments (status, assigned_at desc);
create index delivery_assignments_location_idx
  on public.delivery_assignments (delivery_location_id);

grant select, insert, update on table public.delivery_locations to fleet_backend;
grant select, insert, update on table public.delivery_assignments to fleet_backend;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on table public.delivery_locations from anon;
    revoke all on table public.delivery_assignments from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on table public.delivery_locations from authenticated;
    revoke all on table public.delivery_assignments from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke all on table public.delivery_locations from service_role;
    revoke all on table public.delivery_assignments from service_role;
  end if;
end $$;

alter table public.delivery_locations enable row level security;
alter table public.delivery_assignments enable row level security;

create policy delivery_locations_backend_policy on public.delivery_locations
  for all to fleet_backend using (true) with check (true);
create policy delivery_assignments_backend_policy on public.delivery_assignments
  for all to fleet_backend using (true) with check (true);

-- Source: 20260811030309_configurable_delivery_geofence.sql
-- Add a manager-configurable attendance geofence to each delivery location.
-- Existing locations retain the prior 100-meter behavior.

set lock_timeout = '5s';

alter table public.delivery_locations
  add column radius_meters integer not null default 100
  constraint delivery_locations_radius_check
  check (radius_meters between 10 and 5000);

-- Source: 20260814044007_add_soft_delete_timestamps.sql
alter table public.accounts
  add column deleted_at timestamptz;

alter table public.delivery_locations
  add column deleted_at timestamptz;

create index accounts_current_driver_status_idx
  on public.accounts (role, status)
  where deleted_at is null;

create index delivery_locations_current_name_idx
  on public.delivery_locations (name)
  where deleted_at is null;

-- Source: 20260821090000_multi_dropoff_routes.sql
-- Ordered multi-stop delivery routes. Existing assignments remain intact and
-- are represented by one backfilled stop. FastAPI remains the only data path.

set lock_timeout = '5s';

alter table public.delivery_assignments
  add column route_name text;

create table public.delivery_route_stops (
  id text primary key default gen_random_uuid()::text,
  delivery_assignment_id text not null
    references public.delivery_assignments(id) on delete restrict,
  delivery_location_id text not null
    references public.delivery_locations(id) on delete restrict,
  stop_order integer not null
    constraint delivery_route_stops_order_check check (stop_order > 0),
  completed_at timestamptz,
  removed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index delivery_route_stops_active_order_key
  on public.delivery_route_stops (delivery_assignment_id, stop_order)
  where removed_at is null;
create index delivery_route_stops_location_idx
  on public.delivery_route_stops (delivery_location_id, delivery_assignment_id);

insert into public.delivery_route_stops (
  delivery_assignment_id,
  delivery_location_id,
  stop_order,
  completed_at
)
select
  id,
  delivery_location_id,
  1,
  case when status = 'completed' then completed_at else null end
from public.delivery_assignments;

grant select, insert, update on table public.delivery_route_stops to fleet_backend;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on table public.delivery_route_stops from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on table public.delivery_route_stops from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke all on table public.delivery_route_stops from service_role;
  end if;
end $$;

alter table public.delivery_route_stops enable row level security;

create policy delivery_route_stops_backend_policy
  on public.delivery_route_stops
  for all to fleet_backend using (true) with check (true);

-- Source: 20260823090000_face_reregistration_approval.sql
-- Driver-bound, one-time Fleet Manager approval for face re-registration.
-- The backend stores authorization metadata only.

set lock_timeout = '5s';

create table public.face_reregistration_requests (
  id text primary key default gen_random_uuid()::text,
  driver_account_id text not null unique
    references public.accounts(id) on delete cascade,
  status text not null default 'pending'
    constraint face_reregistration_requests_status_check
    check (status in ('pending', 'approved', 'rejected', 'consumed')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by_manager_id text references public.accounts(id) on delete set null,
  consumed_at timestamptz
);

create index face_reregistration_requests_status_idx
  on public.face_reregistration_requests (status, requested_at desc);

grant select, insert, update on table public.face_reregistration_requests
  to fleet_backend;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on table public.face_reregistration_requests from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on table public.face_reregistration_requests from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke all on table public.face_reregistration_requests from service_role;
  end if;
end $$;

alter table public.face_reregistration_requests enable row level security;

create policy face_reregistration_requests_backend_policy
  on public.face_reregistration_requests
  for all to fleet_backend using (true) with check (true);

-- Source: 20260910090000_driver_device_authorization.sql
-- One active authorized Android installation per Field Personnel account.
-- Stores public-key authorization metadata only; no biometric content or
-- private device key is stored by the backend.

set lock_timeout = '5s';

alter table public.driver_profiles
  add column authorized_device_public_key text,
  add column authorized_device_fingerprint text,
  add column authorized_device_label text,
  add column device_authorized_at timestamptz,
  add column device_authorized_by_manager_id text
    references public.accounts(id) on delete set null,
  add column device_face_enrolled_at timestamptz;

alter table public.driver_profiles
  add constraint driver_profiles_device_fingerprint_length_check
    check (
      authorized_device_fingerprint is null
      or length(authorized_device_fingerprint) = 64
    ),
  add constraint driver_profiles_device_fingerprint_key
    unique (authorized_device_fingerprint);

create index driver_profiles_device_manager_idx
  on public.driver_profiles (device_authorized_by_manager_id);

alter table public.auth_sessions
  add column device_fingerprint text;

alter table public.auth_sessions
  add constraint auth_sessions_device_fingerprint_length_check
    check (device_fingerprint is null or length(device_fingerprint) = 64);

create index auth_sessions_device_fingerprint_idx
  on public.auth_sessions (device_fingerprint);

create table public.device_replacement_requests (
  id text primary key default gen_random_uuid()::text,
  driver_account_id text not null unique
    references public.accounts(id) on delete cascade,
  candidate_public_key text not null,
  candidate_fingerprint text not null
    constraint device_replacement_candidate_fingerprint_length_check
    check (length(candidate_fingerprint) = 64),
  candidate_device_label text,
  status text not null default 'pending'
    constraint device_replacement_requests_status_check
    check (status in ('pending', 'approved', 'rejected')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by_manager_id text references public.accounts(id) on delete set null
);

create index device_replacement_requests_status_idx
  on public.device_replacement_requests (status, requested_at desc);

grant select, insert, update on table public.device_replacement_requests
  to fleet_backend;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on table public.device_replacement_requests from anon;
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    revoke all on table public.device_replacement_requests from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    revoke all on table public.device_replacement_requests from service_role;
  end if;
end $$;

alter table public.device_replacement_requests enable row level security;

create policy device_replacement_requests_backend_policy
  on public.device_replacement_requests
  for all to fleet_backend using (true) with check (true);
