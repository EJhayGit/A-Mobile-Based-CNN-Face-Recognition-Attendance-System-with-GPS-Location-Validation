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
