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
