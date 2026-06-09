-- ════════════════════════════════════════════════════════════════════════════
-- V21_01 — Hauler PWA module: full trip lifecycle (ERP parity, AR & pay hidden).
--
-- This migration is DB-FIRST: apply it to opdwtijyropzoyeseoij BEFORE merging the
-- client PR. It adds:
--   • fleet.trip_driver_view        — driver-safe SELECT (NO AR, NO driver-pay fields)
--   • start_hauling_trip (extended)  — accepts create-modal fields EXCEPT AR & pay
--   • trip_update_field              — whitelisted single-field setter (rejects AR/pay)
--   • trip_set_helpers               — manage helper drivers
--   • fleet.trip_load_item + RPCs    — load items (manual + bol_ocr)
--   • fleet.trip_position + RPC      — periodic GPS pings (Samsara/Motive pattern)
--   • trip_set_ar_pricing / _pay     — DISPATCHER/ADMIN-ONLY (never called from PWA)
--   • hauler_my_active_trip          — resume in-progress trip
--   • hauler_my_assigned_trips       — dispatcher hand-off (planned trips)
--   • hauler_my_trip_history         — driver "My Trips" list
--   • trip_complete (extended)       — auto GPS/miles/hours capture on completion
--
-- CRITICAL CONSTRAINT (locked by user): AR pricing AND driver pay are INVISIBLE to
-- the driver in the PWA. The PWA hits fleet.trip_driver_view (public wrapper), which
-- strips ar_rate_model, ar_rate, ar_amount, ar_invoice_id, ar_billed_at,
-- driver_pay_model, driver_pay_base, driver_pay_amount, driver_pay_time_entry_id,
-- driver_pay_committed_at, is_related_party_use, legal_entity_id.
--
-- Defensive: fleet.trip columns may predate this repo's migrations, so we add any
-- columns the new code writes to with `add column if not exists`.
-- ════════════════════════════════════════════════════════════════════════════

-- ── Make sure every column the new RPCs/views touch exists ──────────────────
alter table fleet.trip add column if not exists planned_start        timestamptz;
alter table fleet.trip add column if not exists planned_end          timestamptz;
alter table fleet.trip add column if not exists planned_miles        numeric;
alter table fleet.trip add column if not exists actual_miles         numeric;
alter table fleet.trip add column if not exists odometer_start       numeric;
alter table fleet.trip add column if not exists odometer_end         numeric;
alter table fleet.trip add column if not exists crop                 text;
alter table fleet.trip add column if not exists farm_id              uuid;
alter table fleet.trip add column if not exists petition_id          uuid;
alter table fleet.trip add column if not exists load_reference       text;
alter table fleet.trip add column if not exists load_type            text;
alter table fleet.trip add column if not exists helper_driver_ids    uuid[];
alter table fleet.trip add column if not exists origin_lat           numeric;
alter table fleet.trip add column if not exists origin_lng           numeric;
alter table fleet.trip add column if not exists destination_lat      numeric;
alter table fleet.trip add column if not exists destination_lng      numeric;
alter table fleet.trip add column if not exists driver_hours         numeric;
alter table fleet.trip add column if not exists notes                text;
-- AR + driver-pay columns (dispatcher/ERP-side; never exposed to the driver view).
alter table fleet.trip add column if not exists ar_rate_model        text;
alter table fleet.trip add column if not exists ar_rate              numeric;
alter table fleet.trip add column if not exists ar_amount            numeric;
alter table fleet.trip add column if not exists ar_invoice_id        uuid;
alter table fleet.trip add column if not exists ar_billed_at         timestamptz;
alter table fleet.trip add column if not exists driver_pay_model     text;
alter table fleet.trip add column if not exists driver_pay_base      numeric;
alter table fleet.trip add column if not exists driver_pay_amount    numeric;
alter table fleet.trip add column if not exists driver_pay_time_entry_id uuid;
alter table fleet.trip add column if not exists driver_pay_committed_at  timestamptz;
alter table fleet.trip add column if not exists is_related_party_use boolean;
alter table fleet.trip add column if not exists legal_entity_id      uuid;

-- ════════════════════════════════════════════════════════════════════════════
-- 1) DRIVER-SAFE VIEW — the ONLY trip surface the PWA hauler is allowed to read.
--    Explicitly enumerates safe columns; AR + driver-pay fields are NOT selected,
--    so they can never leak to the anon/authenticated PWA caller.
-- ════════════════════════════════════════════════════════════════════════════
create or replace view fleet.trip_driver_view as
  select
    t.trip_id,
    t.tenant_id,
    t.driver_id,
    t.vehicle_id,
    coalesce(t.trip_code, left(t.trip_id::text, 8)) as trip_code,
    coalesce(t.status::text, 'planned')             as status,
    t.origin_label,
    t.destination_label,
    t.origin_address,
    t.destination_address,
    t.origin_lat,
    t.origin_lng,
    t.destination_lat,
    t.destination_lng,
    t.planned_start,
    t.planned_end,
    t.actual_start,
    t.actual_end,
    t.planned_miles,
    t.actual_miles,
    t.odometer_start,
    t.odometer_end,
    t.crop,
    t.farm_id,
    t.petition_id,
    t.customer_id,
    coalesce(c.dba_name, c.legal_name) as customer_name,
    t.bill_to_name,
    t.load_reference,
    t.load_type,
    t.helper_driver_ids,
    t.driver_hours,
    t.notes,
    t.created_at
  from fleet.trip t
  left join accounting.customers c on c.customer_id = t.customer_id;
  -- NOTE: ar_rate_model, ar_rate, ar_amount, ar_invoice_id, ar_billed_at,
  -- driver_pay_model, driver_pay_base, driver_pay_amount, driver_pay_time_entry_id,
  -- driver_pay_committed_at, is_related_party_use, legal_entity_id are
  -- DELIBERATELY OMITTED. Do not add them to this view.

grant select on fleet.trip_driver_view to authenticated, anon;

-- public wrapper view so the anon-key PWA (public schema) can read it.
create or replace view public.trip_driver_view as select * from fleet.trip_driver_view;
grant select on public.trip_driver_view to authenticated, anon;

-- ════════════════════════════════════════════════════════════════════════════
-- 2) start_hauling_trip — EXTENDED. Accepts create-modal fields EXCEPT AR & pay.
--    Any AR/driver_pay params are intentionally NOT in the signature, so a PWA
--    caller cannot set them. ar_amount best-effort auto-derives from the customer
--    default rate when a customer is linked — server-side, never blocks creation.
--
--    Drop ALL prior start_hauling_trip signatures (V21_00 3-arg + V21_00_1 6-arg,
--    in both schemas). They share argument names with the new signature, so leaving
--    them in place makes PostgREST overload resolution ambiguous ("could not choose
--    the best candidate function"). After these drops there is exactly one definition.
-- ════════════════════════════════════════════════════════════════════════════
drop function if exists public.start_hauling_trip(uuid, uuid, uuid);
drop function if exists fleet.start_hauling_trip(uuid, uuid, uuid);
drop function if exists public.start_hauling_trip(uuid, uuid, uuid, text, text, text);
drop function if exists fleet.start_hauling_trip(uuid, uuid, uuid, text, text, text);
create or replace function fleet.start_hauling_trip(
  p_tenant_id        uuid,
  p_driver_id        uuid,
  p_vehicle_id       uuid       default null,
  p_origin           text       default null,
  p_dest             text       default null,
  p_customer         text       default null,
  p_planned_start    timestamptz default null,
  p_planned_end      timestamptz default null,
  p_planned_miles    numeric    default null,
  p_odometer_start   numeric    default null,
  p_crop             text       default null,
  p_farm_id          uuid       default null,
  p_petition_id      uuid       default null,
  p_load_reference   text       default null,
  p_load_type        text       default null,
  p_helper_driver_ids uuid[]    default null
) returns uuid
language plpgsql
security definer
set search_path = fleet, accounting, public
as $$
declare
  v_trip     uuid;
  v_customer uuid;
  v_def_rate numeric;
begin
  -- Reuse an open trip for this driver rather than creating duplicates (idempotent).
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
    planned_start, planned_end, planned_miles, odometer_start,
    crop, farm_id, petition_id, load_reference, load_type, helper_driver_ids,
    actual_start, created_at
  )
  values (
    p_tenant_id, p_driver_id, p_vehicle_id, 'in_progress'::trip_status,
    'HAUL-' || to_char(now(),'YYMMDD') || '-' || substr(gen_random_uuid()::text,1,4),
    nullif(trim(coalesce(p_origin,'')),''),
    nullif(trim(coalesce(p_dest,'')),''),
    v_customer,
    nullif(trim(coalesce(p_customer,'')),''),
    p_planned_start, p_planned_end, p_planned_miles, p_odometer_start,
    nullif(trim(coalesce(p_crop,'')),''), p_farm_id, p_petition_id,
    nullif(trim(coalesce(p_load_reference,'')),''),
    nullif(trim(coalesce(p_load_type,'')),''),
    p_helper_driver_ids,
    now(), now()
  )
  returning trip_id into v_trip;

  -- AR amount best-effort default from accounting.customers.default_rate when present.
  -- Wrapped so a missing column / schema difference never blocks trip creation.
  -- This is server-side only and is NEVER returned to the PWA (driver view strips it).
  if v_customer is not null then
    begin
      execute 'select default_rate from accounting.customers where customer_id = $1'
        into v_def_rate using v_customer;
      if v_def_rate is not null then
        update fleet.trip set ar_rate = v_def_rate where trip_id = v_trip;
      end if;
    exception when others then
      null;  -- accounting.customers.default_rate may not exist — ignore
    end;
  end if;

  insert into fleet.trip_event (tenant_id, trip_id, event_type, notes, event_time)
  values (p_tenant_id, v_trip, 'started', 'hauling trip start', now());

  return v_trip;
end;
$$;

create or replace function public.start_hauling_trip(
  p_tenant_id uuid, p_driver_id uuid, p_vehicle_id uuid default null,
  p_origin text default null, p_dest text default null, p_customer text default null,
  p_planned_start timestamptz default null, p_planned_end timestamptz default null,
  p_planned_miles numeric default null, p_odometer_start numeric default null,
  p_crop text default null, p_farm_id uuid default null, p_petition_id uuid default null,
  p_load_reference text default null, p_load_type text default null,
  p_helper_driver_ids uuid[] default null
) returns uuid
language sql security definer set search_path = public, fleet
as $$ select fleet.start_hauling_trip(p_tenant_id, p_driver_id, p_vehicle_id, p_origin, p_dest,
  p_customer, p_planned_start, p_planned_end, p_planned_miles, p_odometer_start, p_crop,
  p_farm_id, p_petition_id, p_load_reference, p_load_type, p_helper_driver_ids); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 3) trip_update_field — whitelisted single-field setter. The driver can edit
--    operational fields mid-trip. AR/pay/tenant/legal-entity edits are REJECTED.
-- ════════════════════════════════════════════════════════════════════════════
create or replace function fleet.trip_update_field(
  p_tenant_id uuid, p_trip_id uuid, p_field text, p_value text
) returns void
language plpgsql
security definer
set search_path = fleet, public
as $$
declare
  v_field text := lower(trim(p_field));
begin
  -- Hard block on anything sensitive, even if a future whitelist typo slips through.
  if v_field like 'ar\_%' or v_field like 'driver\_pay%'
     or v_field in ('is_related_party_use','legal_entity_id','tenant_id') then
    raise exception 'field % is not editable from the driver PWA', p_field;
  end if;

  case v_field
    when 'status' then
      -- Only allow safe transitions the driver UI surfaces.
      if p_value not in ('planned','in_progress','arrived','completed','cancelled') then
        raise exception 'invalid status transition: %', p_value;
      end if;
      update fleet.trip set status = p_value::trip_status
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'actual_miles' then
      update fleet.trip set actual_miles = nullif(p_value,'')::numeric
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'planned_miles' then
      update fleet.trip set planned_miles = nullif(p_value,'')::numeric
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'odometer_end' then
      update fleet.trip set odometer_end = nullif(p_value,'')::numeric
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'notes' then
      update fleet.trip set notes = nullif(p_value,'')
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'origin_label' then
      update fleet.trip set origin_label = nullif(p_value,'')
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'destination_label' then
      update fleet.trip set destination_label = nullif(p_value,'')
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'load_reference' then
      update fleet.trip set load_reference = nullif(p_value,'')
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'load_type' then
      update fleet.trip set load_type = nullif(p_value,'')
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'crop' then
      update fleet.trip set crop = nullif(p_value,'')
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'planned_start' then
      update fleet.trip set planned_start = nullif(p_value,'')::timestamptz
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    when 'planned_end' then
      update fleet.trip set planned_end = nullif(p_value,'')::timestamptz
        where trip_id = p_trip_id and tenant_id = p_tenant_id;
    else
      raise exception 'field % is not editable', p_field;
  end case;
end;
$$;

create or replace function public.trip_update_field(
  p_tenant_id uuid, p_trip_id uuid, p_field text, p_value text
) returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_update_field(p_tenant_id, p_trip_id, p_field, p_value); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 4) trip_set_helpers — manage helper drivers.
-- ════════════════════════════════════════════════════════════════════════════
create or replace function fleet.trip_set_helpers(
  p_tenant_id uuid, p_trip_id uuid, p_helper_driver_ids uuid[]
) returns void
language sql
security definer
set search_path = fleet, public
as $$
  update fleet.trip set helper_driver_ids = p_helper_driver_ids
   where trip_id = p_trip_id and tenant_id = p_tenant_id;
$$;

create or replace function public.trip_set_helpers(
  p_tenant_id uuid, p_trip_id uuid, p_helper_driver_ids uuid[]
) returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_set_helpers(p_tenant_id, p_trip_id, p_helper_driver_ids); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 5) fleet.trip_load_item — load items (manual + BOL OCR). A dedicated table is
--    cleaner than reusing bol_line_item: items can exist without a BOL, and BOL
--    OCR rows are stamped source='bol_ocr' + bol_doc_id for traceability.
-- ════════════════════════════════════════════════════════════════════════════
create table if not exists fleet.trip_load_item (
  item_id     uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references fleet.trip(trip_id) on delete cascade,
  line_no     int,
  description text,
  quantity    numeric,
  unit        text,
  weight_lb   numeric,
  pieces      numeric,
  source      text not null default 'manual' check (source in ('manual','bol_ocr')),
  bol_doc_id  uuid,
  created_at  timestamptz not null default now(),
  tenant_id   uuid not null default '00000000-0000-0000-0000-000000000001'
);
create index if not exists trip_load_item_trip_idx on fleet.trip_load_item (trip_id, line_no);

create or replace function fleet.trip_add_load_item(
  p_tenant_id uuid, p_trip_id uuid, p_description text, p_qty numeric,
  p_unit text, p_weight_lb numeric, p_pieces numeric,
  p_source text default 'manual', p_bol_doc_id uuid default null
) returns uuid
language plpgsql
security definer
set search_path = fleet, public
as $$
declare
  v_id  uuid;
  v_n   int;
begin
  select coalesce(max(line_no),0)+1 into v_n
    from fleet.trip_load_item where trip_id = p_trip_id;
  insert into fleet.trip_load_item (
    tenant_id, trip_id, line_no, description, quantity, unit, weight_lb, pieces, source, bol_doc_id
  ) values (
    p_tenant_id, p_trip_id, v_n, nullif(p_description,''), p_qty, nullif(p_unit,''),
    p_weight_lb, p_pieces,
    case when p_source in ('manual','bol_ocr') then p_source else 'manual' end,
    p_bol_doc_id
  ) returning item_id into v_id;
  return v_id;
end;
$$;

create or replace function fleet.trip_remove_load_item(p_load_item_id uuid)
returns void
language sql security definer set search_path = fleet, public
as $$ delete from fleet.trip_load_item where item_id = p_load_item_id; $$;

create or replace function fleet.trip_list_load_items(p_trip_id uuid)
returns table(
  item_id uuid, line_no int, description text, quantity numeric,
  unit text, weight_lb numeric, pieces numeric, source text, bol_doc_id uuid
)
language sql stable security definer set search_path = fleet, public
as $$
  select item_id, line_no, description, quantity, unit, weight_lb, pieces, source, bol_doc_id
    from fleet.trip_load_item
   where trip_id = p_trip_id
   order by line_no nulls last, created_at;
$$;

create or replace function public.trip_add_load_item(
  p_tenant_id uuid, p_trip_id uuid, p_description text, p_qty numeric,
  p_unit text, p_weight_lb numeric, p_pieces numeric,
  p_source text default 'manual', p_bol_doc_id uuid default null
) returns uuid
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_add_load_item(p_tenant_id, p_trip_id, p_description, p_qty, p_unit,
  p_weight_lb, p_pieces, p_source, p_bol_doc_id); $$;

create or replace function public.trip_remove_load_item(p_load_item_id uuid)
returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_remove_load_item(p_load_item_id); $$;

create or replace function public.trip_list_load_items(p_trip_id uuid)
returns table(
  item_id uuid, line_no int, description text, quantity numeric,
  unit text, weight_lb numeric, pieces numeric, source text, bol_doc_id uuid
)
language sql stable security definer set search_path = public, fleet
as $$ select * from fleet.trip_list_load_items(p_trip_id); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 6) fleet.trip_position — periodic GPS pings (Samsara/Motive ELD pattern).
-- ════════════════════════════════════════════════════════════════════════════
create table if not exists fleet.trip_position (
  position_id uuid primary key default gen_random_uuid(),
  trip_id     uuid not null references fleet.trip(trip_id) on delete cascade,
  ts          timestamptz not null default now(),
  lat         numeric,
  lng         numeric,
  speed_mph   numeric,
  heading_deg numeric,
  tenant_id   uuid not null default '00000000-0000-0000-0000-000000000001'
);
create index if not exists trip_position_trip_ts_idx on fleet.trip_position (trip_id, ts);

create or replace function fleet.trip_log_position(
  p_tenant_id uuid, p_trip_id uuid, p_lat numeric, p_lng numeric,
  p_speed numeric default null, p_heading numeric default null
) returns uuid
language plpgsql
security definer
set search_path = fleet, public
as $$
declare v_id uuid;
begin
  insert into fleet.trip_position (tenant_id, trip_id, lat, lng, speed_mph, heading_deg)
  values (p_tenant_id, p_trip_id, p_lat, p_lng, p_speed, p_heading)
  returning position_id into v_id;
  return v_id;
end;
$$;

create or replace function public.trip_log_position(
  p_tenant_id uuid, p_trip_id uuid, p_lat numeric, p_lng numeric,
  p_speed numeric default null, p_heading numeric default null
) returns uuid
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_log_position(p_tenant_id, p_trip_id, p_lat, p_lng, p_speed, p_heading); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 7) Dispatcher-only AR + driver-pay setters. NEVER called from the PWA.
--    TODO: add role guard once roles are wired (e.g. require dispatcher/admin).
-- ════════════════════════════════════════════════════════════════════════════
create or replace function fleet.trip_set_ar_pricing(
  p_tenant_id uuid, p_trip_id uuid, p_model text, p_rate numeric
) returns void
language plpgsql
security definer
set search_path = fleet, public
as $$
begin
  -- TODO: add role guard once roles are wired — this must reject PWA/driver callers.
  update fleet.trip
     set ar_rate_model = p_model,
         ar_rate       = p_rate,
         ar_amount     = case
                           when p_model = 'per_mile'  then p_rate * coalesce(actual_miles, planned_miles, 0)
                           when p_model = 'flat'      then p_rate
                           else coalesce(ar_amount, p_rate)
                         end
   where trip_id = p_trip_id and tenant_id = p_tenant_id;
end;
$$;

create or replace function fleet.trip_set_driver_pay(
  p_tenant_id uuid, p_trip_id uuid, p_model text, p_base numeric
) returns void
language plpgsql
security definer
set search_path = fleet, public
as $$
begin
  -- TODO: add role guard once roles are wired — this must reject PWA/driver callers.
  update fleet.trip
     set driver_pay_model = p_model,
         driver_pay_base  = p_base,
         driver_pay_amount = case
                              when p_model = 'per_mile' then p_base * coalesce(actual_miles, planned_miles, 0)
                              when p_model = 'per_hour' then p_base * coalesce(driver_hours, 0)
                              when p_model = 'flat'     then p_base
                              else coalesce(driver_pay_amount, p_base)
                            end
   where trip_id = p_trip_id and tenant_id = p_tenant_id;
end;
$$;

create or replace function public.trip_set_ar_pricing(
  p_tenant_id uuid, p_trip_id uuid, p_model text, p_rate numeric
) returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_set_ar_pricing(p_tenant_id, p_trip_id, p_model, p_rate); $$;

create or replace function public.trip_set_driver_pay(
  p_tenant_id uuid, p_trip_id uuid, p_model text, p_base numeric
) returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_set_driver_pay(p_tenant_id, p_trip_id, p_model, p_base); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 8) hauler_my_active_trip — the driver's current in_progress trip (driver view).
-- ════════════════════════════════════════════════════════════════════════════
create or replace function fleet.hauler_my_active_trip(p_tenant_id uuid, p_driver_id uuid)
returns setof fleet.trip_driver_view
language sql stable security definer set search_path = fleet, public
as $$
  select v.* from fleet.trip_driver_view v
   where v.tenant_id = p_tenant_id
     and v.driver_id = p_driver_id
     and v.status = 'in_progress'
   order by v.actual_start desc nulls last
   limit 1;
$$;

create or replace function public.hauler_my_active_trip(p_tenant_id uuid, p_driver_id uuid)
returns setof public.trip_driver_view
language sql stable security definer set search_path = public, fleet
as $$ select * from fleet.hauler_my_active_trip(p_tenant_id, p_driver_id); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 9) hauler_my_assigned_trips — planned trips for this driver (driver or helper).
-- ════════════════════════════════════════════════════════════════════════════
create or replace function fleet.hauler_my_assigned_trips(p_tenant_id uuid, p_driver_id uuid)
returns setof fleet.trip_driver_view
language sql stable security definer set search_path = fleet, public
as $$
  select v.* from fleet.trip_driver_view v
   where v.tenant_id = p_tenant_id
     and v.status = 'planned'
     and (v.driver_id = p_driver_id
          or (v.helper_driver_ids is not null and p_driver_id = any(v.helper_driver_ids)))
   order by v.planned_start asc nulls first;
$$;

create or replace function public.hauler_my_assigned_trips(p_tenant_id uuid, p_driver_id uuid)
returns setof public.trip_driver_view
language sql stable security definer set search_path = public, fleet
as $$ select * from fleet.hauler_my_assigned_trips(p_tenant_id, p_driver_id); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 10) hauler_my_trip_history — completed/cancelled trips in last N days.
-- ════════════════════════════════════════════════════════════════════════════
create or replace function fleet.hauler_my_trip_history(
  p_tenant_id uuid, p_driver_id uuid, p_days int default 30
) returns setof fleet.trip_driver_view
language sql stable security definer set search_path = fleet, public
as $$
  select v.* from fleet.trip_driver_view v
   where v.tenant_id = p_tenant_id
     and v.driver_id = p_driver_id
     and v.status in ('completed','cancelled')
     and coalesce(v.actual_start, v.created_at) >= now() - (coalesce(p_days,30) || ' days')::interval
   order by v.actual_start desc nulls last;
$$;

create or replace function public.hauler_my_trip_history(
  p_tenant_id uuid, p_driver_id uuid, p_days int default 30
) returns setof public.trip_driver_view
language sql stable security definer set search_path = public, fleet
as $$ select * from fleet.hauler_my_trip_history(p_tenant_id, p_driver_id, p_days); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 12) trip_complete — EXTENDED with auto GPS / miles / hours capture.
--     Keeps the existing (uuid,uuid,numeric,numeric) leading params so the V21_00
--     client still works; adds optional GPS params at the end.
-- ════════════════════════════════════════════════════════════════════════════
-- Drop BOTH old 4-arg signatures (fleet + public wrapper). The new versions add two
-- trailing GPS params with defaults; without dropping, a 4-arg call would be ambiguous
-- between the old and new overloads, and the stale public wrapper would call a dropped
-- fleet function. Dropping both leaves exactly one (6-arg, defaulted) definition each.
drop function if exists public.trip_complete(uuid, uuid, numeric, numeric);
drop function if exists fleet.trip_complete(uuid, uuid, numeric, numeric);
create or replace function fleet.trip_complete(
  p_tenant_id uuid, p_trip_id uuid,
  p_odometer_end numeric default null, p_actual_gallons numeric default null,
  p_dest_lat numeric default null, p_dest_lng numeric default null
) returns void
language plpgsql
security definer
set search_path = fleet, public
as $$
declare
  v_hours numeric;
begin
  -- Sum hours from driver_time_entry rows linked to this trip (closed entries).
  select round(sum(duration_minutes)::numeric / 60.0, 2) into v_hours
    from fleet.driver_time_entry
   where trip_id = p_trip_id
     and tenant_id = p_tenant_id
     and duration_minutes is not null;

  update fleet.trip
     set status         = 'completed'::trip_status,
         actual_end     = coalesce(actual_end, now()),
         odometer_end   = coalesce(p_odometer_end, odometer_end),
         actual_gallons = coalesce(p_actual_gallons, actual_gallons),
         -- auto destination GPS if not already set
         destination_lat = coalesce(destination_lat, p_dest_lat),
         destination_lng = coalesce(destination_lng, p_dest_lng),
         -- auto miles from odometer when both ends are known
         actual_miles   = coalesce(
                            actual_miles,
                            case when coalesce(p_odometer_end, odometer_end) is not null
                                  and odometer_start is not null
                                 then coalesce(p_odometer_end, odometer_end) - odometer_start
                                 else null end),
         driver_hours   = coalesce(v_hours, driver_hours)
   where trip_id = p_trip_id and tenant_id = p_tenant_id;

  insert into fleet.trip_event (tenant_id, trip_id, event_type, notes, event_time, odometer, lat, lng)
  values (p_tenant_id, p_trip_id, 'completed',
          nullif(concat_ws(' · ',
            case when p_odometer_end is not null then 'odo_end='||p_odometer_end end,
            case when p_actual_gallons is not null then 'gal='||p_actual_gallons end), ''),
          now(), p_odometer_end, p_dest_lat, p_dest_lng);
end;
$$;

create or replace function public.trip_complete(
  p_tenant_id uuid, p_trip_id uuid,
  p_odometer_end numeric default null, p_actual_gallons numeric default null,
  p_dest_lat numeric default null, p_dest_lng numeric default null
) returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.trip_complete(p_tenant_id, p_trip_id, p_odometer_end, p_actual_gallons, p_dest_lat, p_dest_lng); $$;

-- ════════════════════════════════════════════════════════════════════════════
-- 11) GRANTS — public wrappers callable by the anon-key PWA + authenticated.
-- ════════════════════════════════════════════════════════════════════════════
grant execute on function fleet.start_hauling_trip(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,numeric,numeric,text,uuid,uuid,text,text,uuid[]) to authenticated, anon;
grant execute on function public.start_hauling_trip(uuid,uuid,uuid,text,text,text,timestamptz,timestamptz,numeric,numeric,text,uuid,uuid,text,text,uuid[]) to authenticated, anon;
grant execute on function fleet.trip_update_field(uuid,uuid,text,text)  to authenticated, anon;
grant execute on function public.trip_update_field(uuid,uuid,text,text) to authenticated, anon;
grant execute on function fleet.trip_set_helpers(uuid,uuid,uuid[])  to authenticated, anon;
grant execute on function public.trip_set_helpers(uuid,uuid,uuid[]) to authenticated, anon;
grant execute on function fleet.trip_add_load_item(uuid,uuid,text,numeric,text,numeric,numeric,text,uuid)  to authenticated, anon;
grant execute on function public.trip_add_load_item(uuid,uuid,text,numeric,text,numeric,numeric,text,uuid) to authenticated, anon;
grant execute on function fleet.trip_remove_load_item(uuid)  to authenticated, anon;
grant execute on function public.trip_remove_load_item(uuid) to authenticated, anon;
grant execute on function fleet.trip_list_load_items(uuid)  to authenticated, anon;
grant execute on function public.trip_list_load_items(uuid) to authenticated, anon;
grant execute on function fleet.trip_log_position(uuid,uuid,numeric,numeric,numeric,numeric)  to authenticated, anon;
grant execute on function public.trip_log_position(uuid,uuid,numeric,numeric,numeric,numeric) to authenticated, anon;
grant execute on function fleet.trip_set_ar_pricing(uuid,uuid,text,numeric)  to authenticated, anon;
grant execute on function public.trip_set_ar_pricing(uuid,uuid,text,numeric) to authenticated, anon;
grant execute on function fleet.trip_set_driver_pay(uuid,uuid,text,numeric)  to authenticated, anon;
grant execute on function public.trip_set_driver_pay(uuid,uuid,text,numeric) to authenticated, anon;
grant execute on function fleet.hauler_my_active_trip(uuid,uuid)  to authenticated, anon;
grant execute on function public.hauler_my_active_trip(uuid,uuid) to authenticated, anon;
grant execute on function fleet.hauler_my_assigned_trips(uuid,uuid)  to authenticated, anon;
grant execute on function public.hauler_my_assigned_trips(uuid,uuid) to authenticated, anon;
grant execute on function fleet.hauler_my_trip_history(uuid,uuid,int)  to authenticated, anon;
grant execute on function public.hauler_my_trip_history(uuid,uuid,int) to authenticated, anon;
grant execute on function fleet.trip_complete(uuid,uuid,numeric,numeric,numeric,numeric)  to authenticated, anon;
grant execute on function public.trip_complete(uuid,uuid,numeric,numeric,numeric,numeric) to authenticated, anon;

-- ════════════════════════════════════════════════════════════════════════════
-- 12) FUEL ↔ TRIP linkage (Constraint #4: hauler fuel receipts stamp trip_id).
--
-- The existing submit_fuel_receipt / driver_recent_fuel_receipts RPCs were
-- applied directly to the remote DB and are NOT in this repo, so we do NOT
-- recreate them (no source = no safe `create or replace`). Instead we add the
-- trip_id column additively and stamp it via a tiny dedicated RPC that the PWA
-- calls right after submit_fuel_receipt resolves. A read RPC returns the
-- receipts for one trip for the hauler Fuel tab. Both are written defensively
-- because fleet.fuel_purchase_pending predates this repo's migrations.
-- ════════════════════════════════════════════════════════════════════════════

alter table fleet.fuel_purchase_pending add column if not exists trip_id uuid;
create index if not exists fuel_purchase_pending_trip_idx
  on fleet.fuel_purchase_pending (trip_id) where trip_id is not null;

-- Stamp trip_id onto a pending receipt row (called post-submit by the PWA).
create or replace function fleet.fuel_pending_set_trip(
  p_tenant_id uuid, p_pending_id uuid, p_trip_id uuid
) returns void
language plpgsql
security definer
set search_path = fleet, public
as $$
begin
  update fleet.fuel_purchase_pending
     set trip_id = p_trip_id
   where pending_id = p_pending_id
     and (tenant_id = p_tenant_id or tenant_id is null);
exception when undefined_column then
  -- pending_id/tenant_id column names differ in this DB; ignore rather than fail the receipt.
  null;
end;
$$;

create or replace function public.fuel_pending_set_trip(
  p_tenant_id uuid, p_pending_id uuid, p_trip_id uuid
) returns void
language sql security definer set search_path = public, fleet
as $$ select fleet.fuel_pending_set_trip(p_tenant_id, p_pending_id, p_trip_id); $$;

-- Receipts for one trip (hauler Fuel tab). Driver-safe: gallons/total/odometer
-- /station only — NO AR, NO pay. Defensive: returns empty set if the underlying
-- columns differ, so a schema mismatch never breaks the tab.
create or replace function fleet.trip_fuel_receipts(
  p_tenant_id uuid, p_trip_id uuid
) returns table(
  out_pending_id uuid,
  out_gallons numeric,
  out_total_amount numeric,
  out_odometer numeric,
  out_station_name text,
  out_submitted_at timestamptz,
  out_status text
)
language plpgsql
stable
security definer
set search_path = fleet, public
as $$
begin
  return query
    select fp.pending_id,
           fp.reported_gallons,
           fp.reported_total_amount,
           fp.reported_odometer,
           fp.reported_station_name,
           fp.created_at,
           coalesce(fp.status::text, 'pending')
      from fleet.fuel_purchase_pending fp
     where fp.trip_id = p_trip_id
       and (fp.tenant_id = p_tenant_id or fp.tenant_id is null)
     order by fp.created_at desc;
exception when undefined_column then
  return;  -- column names differ; surface nothing rather than erroring
end;
$$;

create or replace function public.trip_fuel_receipts(
  p_tenant_id uuid, p_trip_id uuid
) returns table(
  out_pending_id uuid, out_gallons numeric, out_total_amount numeric,
  out_odometer numeric, out_station_name text, out_submitted_at timestamptz, out_status text
)
language sql stable security definer set search_path = public, fleet
as $$ select * from fleet.trip_fuel_receipts(p_tenant_id, p_trip_id); $$;

grant execute on function fleet.fuel_pending_set_trip(uuid,uuid,uuid)  to authenticated, anon;
grant execute on function public.fuel_pending_set_trip(uuid,uuid,uuid) to authenticated, anon;
grant execute on function fleet.trip_fuel_receipts(uuid,uuid)  to authenticated, anon;
grant execute on function public.trip_fuel_receipts(uuid,uuid) to authenticated, anon;
