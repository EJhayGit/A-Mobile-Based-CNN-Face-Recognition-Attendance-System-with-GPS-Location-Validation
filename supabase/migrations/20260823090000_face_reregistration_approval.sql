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
