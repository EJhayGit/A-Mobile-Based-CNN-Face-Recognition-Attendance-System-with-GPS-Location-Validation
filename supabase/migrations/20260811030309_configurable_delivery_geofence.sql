-- Add a manager-configurable attendance geofence to each delivery location.
-- Existing locations retain the prior 100-meter behavior.

set lock_timeout = '5s';

alter table public.delivery_locations
  add column radius_meters integer not null default 100
  constraint delivery_locations_radius_check
  check (radius_meters between 10 and 5000);
