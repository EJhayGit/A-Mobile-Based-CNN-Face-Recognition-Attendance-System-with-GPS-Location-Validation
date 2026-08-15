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
