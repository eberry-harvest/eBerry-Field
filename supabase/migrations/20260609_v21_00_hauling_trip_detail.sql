-- V21_00 — Fix #4: Hauling Trip Detail support
-- Read RPC for the detail screen + pause/resume/complete trip-event writers.
-- fleet.trip_event already exists with: event_id, trip_id, event_time, event_type,
-- location_label, lat, lng, odometer, notes, created_at, tenant_id.
-- fleet.trip.status is an enum trip_status with values: planned | in_progress | completed | cancelled.
-- We do NOT mutate trip.status on pause/resume — pause is recorded as a trip_event only.

create index if not exists trip_event_trip_idx on fleet.trip_event (trip_id, event_time);

create or replace function fleet.trip_detail(p_tenant_id uuid, p_trip_id uuid)
returns table(
  trip_id uuid,
  trip_code text,
  status text,
  origin_name text,
  origin_address text,
  dest_name text,
  dest_address text,
  planned_miles numeric,
  actual_miles numeric,
  actual_start timestamptz,
  actual_end timestamptz,
  bill_to_customer_id uuid,
  bill_to_name text,
  is_related_party_use boolean,
  events jsonb
)
language sql
stable
security definer
set search_path = fleet, accounting, public
as $$
  select t.trip_id,
         coalesce(t.trip_code, left(t.trip_id::text, 8)) as trip_code,
         coalesce(t.status::text, 'planned') as status,
         t.origin_label as origin_name,
         t.origin_address,
         t.destination_label as dest_name,
         t.destination_address as dest_address,
         t.planned_miles,
         t.actual_miles,
         t.actual_start,
         t.actual_end,
         t.customer_id as bill_to_customer_id,
         coalesce(c.dba_name, c.legal_name) as bill_to_name,
         coalesce(t.is_related_party_use, false) as is_related_party_use,
         coalesce((
           select jsonb_agg(jsonb_build_object(
             'event_type', e.event_type,
             'notes', e.notes,
             'occurred_at', e.event_time,
             'location_label', e.location_label,
             'odometer', e.odometer
           ) order by e.event_time)
           from fleet.trip_event e where e.trip_id = t.trip_id
         ), '[]'::jsonb) as events
    from fleet.trip t
    left join accounting.customers c on c.customer_id = t.customer_id
   where t.tenant_id = p_tenant_id
     and t.trip_id = p_trip_id;
$$;

create or replace function fleet.trip_add_event(
  p_tenant_id uuid, p_trip_id uuid, p_event_type text, p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = fleet, public
as $$
declare v_id uuid;
begin
  insert into fleet.trip_event (tenant_id, trip_id, event_type, notes, event_time)
  values (p_tenant_id, p_trip_id, p_event_type, p_notes, now())
  returning event_id into v_id;
  return v_id;
end;
$$;

create or replace function fleet.trip_complete(
  p_tenant_id uuid, p_trip_id uuid, p_odometer_end numeric default null, p_actual_gallons numeric default null
) returns void
language plpgsql
security definer
set search_path = fleet, public
as $$
begin
  update fleet.trip
     set status = 'completed'::trip_status,
         actual_end = coalesce(actual_end, now()),
         odometer_end = coalesce(p_odometer_end, odometer_end),
         actual_gallons = coalesce(p_actual_gallons, actual_gallons)
   where trip_id = p_trip_id and tenant_id = p_tenant_id;

  insert into fleet.trip_event (tenant_id, trip_id, event_type, notes, event_time, odometer)
  values (p_tenant_id, p_trip_id, 'completed',
          nullif(concat_ws(' · ',
            case when p_odometer_end is not null then 'odo_end='||p_odometer_end end,
            case when p_actual_gallons is not null then 'gal='||p_actual_gallons end), ''),
          now(), p_odometer_end);
end;
$$;

create or replace function fleet.start_hauling_trip(
  p_tenant_id uuid,
  p_driver_id uuid,
  p_vehicle_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = fleet, public
as $$
declare
  v_trip uuid;
begin
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

  insert into fleet.trip (tenant_id, driver_id, vehicle_id, status, trip_code, actual_start, created_at)
  values (p_tenant_id, p_driver_id, p_vehicle_id, 'in_progress'::trip_status,
          'HAUL-' || to_char(now(),'YYMMDD') || '-' || substr(gen_random_uuid()::text,1,4),
          now(), now())
  returning trip_id into v_trip;

  insert into fleet.trip_event (tenant_id, trip_id, event_type, notes, event_time)
  values (p_tenant_id, v_trip, 'started', 'hauling trip start', now());

  return v_trip;
end;
$$;

create or replace function public.start_hauling_trip(
  p_tenant_id uuid, p_driver_id uuid, p_vehicle_id uuid default null
) returns uuid
language sql security definer set search_path = public, fleet
as $$ select fleet.start_hauling_trip(p_tenant_id, p_driver_id, p_vehicle_id); $$;

create or replace function public.trip_detail(p_tenant_id uuid, p_trip_id uuid)
returns table(
  trip_id uuid, trip_code text, status text, origin_name text, origin_address text,
  dest_name text, dest_address text, planned_miles numeric, actual_miles numeric,
  actual_start timestamptz, actual_end timestamptz, bill_to_customer_id uuid,
  bill_to_name text, is_related_party_use boolean, events jsonb
)
language sql stable security definer set search_path = public, fleet
as $$ select * from fleet.trip_detail(p_tenant_id, p_trip_id); $$;

create or replace function public.trip_add_event(
  p_tenant_id uuid, p_trip_id uuid, p_event_type text, p_notes text default null
) returns uuid
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_add_event(p_tenant_id, p_trip_id, p_event_type, p_notes); $$;

create or replace function public.trip_complete(
  p_tenant_id uuid, p_trip_id uuid, p_odometer_end numeric default null, p_actual_gallons numeric default null
) returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_complete(p_tenant_id, p_trip_id, p_odometer_end, p_actual_gallons); $$;

grant execute on function fleet.start_hauling_trip(uuid,uuid,uuid) to authenticated, anon;
grant execute on function public.start_hauling_trip(uuid,uuid,uuid) to authenticated, anon;
grant execute on function fleet.trip_detail(uuid,uuid) to authenticated, anon;
grant execute on function public.trip_detail(uuid,uuid) to authenticated, anon;
grant execute on function fleet.trip_add_event(uuid,uuid,text,text) to authenticated, anon;
grant execute on function public.trip_add_event(uuid,uuid,text,text) to authenticated, anon;
grant execute on function fleet.trip_complete(uuid,uuid,numeric,numeric) to authenticated, anon;
grant execute on function public.trip_complete(uuid,uuid,numeric,numeric) to authenticated, anon;
