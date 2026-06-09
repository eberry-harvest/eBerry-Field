-- V21_00_1 — Hauler start screen support.
-- The V21_00 client created a hauling trip with driver+vehicle only and dropped the
-- user on the chofer Driver tabs. V21_00_1 gives Hauler its own start screen that
-- collects vehicle + origin/destination/customer up front, so start_hauling_trip now
-- accepts those optional text params and seeds the trip with them.
--
-- Defensive: fleet.trip columns may predate this repo's migrations, so we add any
-- missing columns the function writes to. customer matching is best-effort by name;
-- if no match we still keep the typed name in bill_to_name for the detail screen.

alter table fleet.trip add column if not exists origin_label        text;
alter table fleet.trip add column if not exists destination_label   text;
alter table fleet.trip add column if not exists customer_id          uuid;
alter table fleet.trip add column if not exists bill_to_name         text;

create or replace function fleet.start_hauling_trip(
  p_tenant_id  uuid,
  p_driver_id  uuid,
  p_vehicle_id uuid default null,
  p_origin     text default null,
  p_dest       text default null,
  p_customer   text default null
) returns uuid
language plpgsql
security definer
set search_path = fleet, accounting, public
as $$
declare
  v_trip     uuid;
  v_customer uuid;
begin
  -- Reuse an open trip for this driver rather than creating duplicates.
  select trip_id into v_trip
    from fleet.trip
   where tenant_id = p_tenant_id
     and driver_id = p_driver_id
     and coalesce(status::text,'planned') not in ('completed','cancelled')
   order by coalesce(actual_start, created_at) desc nulls last
   limit 1;

  if v_trip is not null then
    return v_trip;
  end if;

  -- Best-effort customer match by dba/legal name (case-insensitive).
  if p_customer is not null and length(trim(p_customer)) > 0 then
    begin
      select customer_id into v_customer
        from accounting.customers
       where tenant_id = p_tenant_id
         and (lower(dba_name) = lower(trim(p_customer))
              or lower(legal_name) = lower(trim(p_customer)))
       limit 1;
    exception when others then
      v_customer := null;  -- schema differences must not block trip creation
    end;
  end if;

  insert into fleet.trip (
    tenant_id, driver_id, vehicle_id, status, trip_code,
    origin_label, destination_label, customer_id, bill_to_name,
    actual_start, created_at
  )
  values (
    p_tenant_id, p_driver_id, p_vehicle_id, 'in_progress'::trip_status,
    'HAUL-' || to_char(now(),'YYMMDD') || '-' || substr(gen_random_uuid()::text,1,4),
    nullif(trim(coalesce(p_origin,'')),''),
    nullif(trim(coalesce(p_dest,'')),''),
    v_customer,
    nullif(trim(coalesce(p_customer,'')),''),
    now(), now()
  )
  returning trip_id into v_trip;

  insert into fleet.trip_event (tenant_id, trip_id, event_type, notes, event_time)
  values (p_tenant_id, v_trip, 'started', 'hauling trip start', now());

  return v_trip;
end;
$$;

create or replace function public.start_hauling_trip(
  p_tenant_id uuid, p_driver_id uuid, p_vehicle_id uuid default null,
  p_origin text default null, p_dest text default null, p_customer text default null
) returns uuid
language sql security definer set search_path = public, fleet
as $$ select fleet.start_hauling_trip(p_tenant_id, p_driver_id, p_vehicle_id, p_origin, p_dest, p_customer); $$;

grant execute on function fleet.start_hauling_trip(uuid,uuid,uuid,text,text,text)  to authenticated, anon;
grant execute on function public.start_hauling_trip(uuid,uuid,uuid,text,text,text) to authenticated, anon;
