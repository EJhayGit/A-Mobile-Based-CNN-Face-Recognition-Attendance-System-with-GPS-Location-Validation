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
