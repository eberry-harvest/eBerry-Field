-- V21_00 — Fix #3: BOL OCR storage
-- fleet.bol_document + fleet.bol_line_item + match_bill_to fuzzy customer lookup.

create table if not exists fleet.bol_document (
  bol_doc_id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default '00000000-0000-0000-0000-000000000001',
  trip_id uuid references fleet.trip(trip_id),
  bol_number text,
  bill_to_name text,
  bill_to_customer_id uuid references accounting.customers(customer_id),
  shipper_name text,
  consignee_name text,
  carrier_name text,
  pickup_date date,
  delivery_date date,
  commodity_summary text,
  total_pieces numeric,
  total_weight_lbs numeric,
  freight_terms text,
  source_image_url text,
  ocr_json jsonb,
  ocr_status text default 'pending', -- pending | parsed | confirmed | failed
  ocr_confidence numeric,
  created_at timestamptz default now(),
  created_by uuid,
  confirmed_at timestamptz,
  confirmed_by uuid
);

create table if not exists fleet.bol_line_item (
  bol_line_id uuid primary key default gen_random_uuid(),
  bol_doc_id uuid not null references fleet.bol_document(bol_doc_id) on delete cascade,
  line_no int not null,
  description text,
  qty numeric,
  unit text,
  piece_count numeric,
  weight_lbs numeric,
  lot_number text,
  tenant_id uuid not null default '00000000-0000-0000-0000-000000000001'
);

create index if not exists bol_document_trip_idx on fleet.bol_document (tenant_id, trip_id);
create index if not exists bol_line_item_doc_idx on fleet.bol_line_item (bol_doc_id, line_no);

-- ── Fuzzy bill-to match (top-3 candidates by trigram similarity) ──
create extension if not exists pg_trgm;

create or replace function fleet.match_bill_to(p_tenant_id uuid, p_name text)
returns table(customer_id uuid, customer_name text, similarity real)
language sql
stable
security definer
set search_path = fleet, accounting, public
as $$
  select c.customer_id,
         coalesce(c.dba_name, c.legal_name) as customer_name,
         similarity(coalesce(c.dba_name, c.legal_name), p_name) as similarity
    from accounting.customers c
   where c.tenant_id = p_tenant_id
     and coalesce(c.is_active, true) = true
     and p_name is not null
     and length(trim(p_name)) > 0
   order by similarity(coalesce(c.dba_name, c.legal_name), p_name) desc
   limit 3;
$$;

create or replace function public.match_bill_to(p_tenant_id uuid, p_name text)
returns table(customer_id uuid, customer_name text, similarity real)
language sql
stable
security definer
set search_path = public, fleet, accounting
as $$ select * from fleet.match_bill_to(p_tenant_id, p_name); $$;

-- ── Save / confirm a BOL document + its line items in one call ──
create or replace function fleet.save_bol_document(
  p_tenant_id uuid,
  p_trip_id uuid,
  p_bol_doc jsonb,
  p_line_items jsonb,
  p_bill_to_customer_id uuid default null,
  p_source_image_url text default null,
  p_confirmed_by uuid default null
) returns uuid
language plpgsql
security definer
set search_path = fleet, public
as $$
declare
  v_doc_id uuid;
  v_item jsonb;
  v_n int := 0;
begin
  insert into fleet.bol_document (
    tenant_id, trip_id, bol_number, bill_to_name, bill_to_customer_id,
    shipper_name, consignee_name, carrier_name, pickup_date, delivery_date,
    commodity_summary, total_pieces, total_weight_lbs, freight_terms,
    source_image_url, ocr_json, ocr_status, ocr_confidence,
    created_by, confirmed_at, confirmed_by
  ) values (
    p_tenant_id,
    p_trip_id,
    nullif(p_bol_doc->>'bol_number',''),
    nullif(p_bol_doc->>'bill_to_name',''),
    p_bill_to_customer_id,
    nullif(p_bol_doc->>'shipper_name',''),
    nullif(p_bol_doc->>'consignee_name',''),
    nullif(p_bol_doc->>'carrier_name',''),
    (nullif(p_bol_doc->>'pickup_date',''))::date,
    (nullif(p_bol_doc->>'delivery_date',''))::date,
    nullif(p_bol_doc->>'commodity_summary',''),
    (nullif(p_bol_doc->>'total_pieces',''))::numeric,
    (nullif(p_bol_doc->>'total_weight_lbs',''))::numeric,
    nullif(p_bol_doc->>'freight_terms',''),
    p_source_image_url,
    p_bol_doc,
    'confirmed',
    (nullif(p_bol_doc->>'ocr_confidence',''))::numeric,
    p_confirmed_by,
    now(),
    p_confirmed_by
  ) returning bol_doc_id into v_doc_id;

  if p_line_items is not null then
    for v_item in select * from jsonb_array_elements(p_line_items)
    loop
      v_n := v_n + 1;
      insert into fleet.bol_line_item (
        bol_doc_id, line_no, description, qty, unit, piece_count, weight_lbs, lot_number, tenant_id
      ) values (
        v_doc_id,
        coalesce((nullif(v_item->>'line_no',''))::int, v_n),
        nullif(v_item->>'description',''),
        (nullif(v_item->>'qty',''))::numeric,
        nullif(v_item->>'unit',''),
        (nullif(v_item->>'piece_count',''))::numeric,
        (nullif(v_item->>'weight_lbs',''))::numeric,
        nullif(v_item->>'lot_number',''),
        p_tenant_id
      );
    end loop;
  end if;

  return v_doc_id;
end;
$$;

create or replace function public.save_bol_document(
  p_tenant_id uuid,
  p_trip_id uuid,
  p_bol_doc jsonb,
  p_line_items jsonb,
  p_bill_to_customer_id uuid default null,
  p_source_image_url text default null,
  p_confirmed_by uuid default null
) returns uuid
language sql
security definer
set search_path = public, fleet
as $$ select fleet.save_bol_document(p_tenant_id, p_trip_id, p_bol_doc, p_line_items, p_bill_to_customer_id, p_source_image_url, p_confirmed_by); $$;

-- ── Read a BOL document + line items for the Trip Detail screen ──
create or replace function fleet.trip_bol(p_tenant_id uuid, p_trip_id uuid)
returns table(
  bol_doc_id uuid,
  bol_number text,
  bill_to_name text,
  shipper_name text,
  consignee_name text,
  carrier_name text,
  commodity_summary text,
  total_pieces numeric,
  total_weight_lbs numeric,
  freight_terms text,
  source_image_url text,
  ocr_json jsonb,
  line_items jsonb
)
language sql
stable
security definer
set search_path = fleet, public
as $$
  select d.bol_doc_id, d.bol_number, d.bill_to_name, d.shipper_name, d.consignee_name,
         d.carrier_name, d.commodity_summary, d.total_pieces, d.total_weight_lbs,
         d.freight_terms, d.source_image_url, d.ocr_json,
         coalesce((
           select jsonb_agg(jsonb_build_object(
             'bol_line_id', li.bol_line_id, 'line_no', li.line_no, 'description', li.description,
             'qty', li.qty, 'unit', li.unit, 'piece_count', li.piece_count,
             'weight_lbs', li.weight_lbs, 'lot_number', li.lot_number) order by li.line_no)
           from fleet.bol_line_item li where li.bol_doc_id = d.bol_doc_id
         ), '[]'::jsonb) as line_items
    from fleet.bol_document d
   where d.tenant_id = p_tenant_id
     and d.trip_id = p_trip_id
   order by d.created_at desc
   limit 1;
$$;

create or replace function public.trip_bol(p_tenant_id uuid, p_trip_id uuid)
returns table(
  bol_doc_id uuid, bol_number text, bill_to_name text, shipper_name text,
  consignee_name text, carrier_name text, commodity_summary text,
  total_pieces numeric, total_weight_lbs numeric, freight_terms text,
  source_image_url text, ocr_json jsonb, line_items jsonb
)
language sql
stable
security definer
set search_path = public, fleet
as $$ select * from fleet.trip_bol(p_tenant_id, p_trip_id); $$;

grant execute on function fleet.match_bill_to(uuid,text) to authenticated, anon;
grant execute on function public.match_bill_to(uuid,text) to authenticated, anon;
grant execute on function fleet.save_bol_document(uuid,uuid,jsonb,jsonb,uuid,text,uuid) to authenticated, anon;
grant execute on function public.save_bol_document(uuid,uuid,jsonb,jsonb,uuid,text,uuid) to authenticated, anon;
grant execute on function fleet.trip_bol(uuid,uuid) to authenticated, anon;
grant execute on function public.trip_bol(uuid,uuid) to authenticated, anon;
