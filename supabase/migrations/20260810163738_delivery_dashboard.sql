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
