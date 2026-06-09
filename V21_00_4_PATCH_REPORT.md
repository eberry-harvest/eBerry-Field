# V21_00_4 Patch Report — RPC verification + fixes

**Date:** 2026-06-09
**Base:** index_V21_00_3.html (15,305 lines)
**Output:** index_V21_00_4.html (15,316 lines)
**APP_VERSION:** `'V21_00_4'`

## Scope

Verify all 10 open questions from V21_00_3 merge report against the live DB and patch any mismatches. No new features — pure correctness.

## Open-question verification

| # | RPC / surface | DB reality | V21_00_3 call | Verdict |
|---|---|---|---|---|
| 1 | `trip_list_load_items(p_trip_id uuid)` | Exists in fleet & public; sig: `(p_trip_id uuid)` returning `TABLE(out_item_id, out_line_no, out_description, out_quantity, out_unit, out_weight_lb, out_pieces, out_source, out_bol_doc_id)` | `rpc('trip_list_load_items', { p_trip_id: tripId })` | ✅ Match — no change |
| 2 | `trip_remove_load_item(p_load_item_id uuid)` returns void | Exists | `rpc('trip_remove_load_item', { p_load_item_id: id })` | ✅ Match — no change |
| 3 | `submit_maintenance_event(p_maintenance_id, p_driver_id, p_vehicle_id, p_event_date, p_service_category, p_description, p_odometer_reading, p_parts_cost, p_photo_url, p_notes)` | V21_00_3 calls with `p_pending_id`, `p_event_type`, `p_occurred_at` — **WRONG NAMES, MISSING REQUIRED PARAMS** | ❌ **FIXED in V21_00_4** (3 call sites) |
| 4 | `driver_check_inspection_today(p_vehicle_id, p_inspection_type)` returns TABLE | Exists | Matches call sites | ✅ Match — no change |
| 5 | `trip_bol(p_tenant_id, p_trip_id)` returns TABLE incl. `line_items jsonb`, `source_image_url text` | Exists with expected return shape | `rpc('trip_bol', { p_tenant_id: TENANT_ID, p_trip_id: tripId })` | ✅ Match — no change |
| 6 | `trip_update_field(p_tenant_id, p_trip_id, p_field text, p_value text)` returns void | Exists | `C.startPlannedTrip` passes `p_field:'status', p_value:'in_progress'` | ✅ Match — status flip works |
| 7 | `hauler_my_active_trip` returns SETOF `trip_driver_view`. **rancho_origin was NOT in the view** | Code references `trip.rancho_origin` in Overview tab — would always be null | ❌ **FIXED in V21_00_4** (DB migration recreates view to add `t.rancho_origin`) |
| 8 | `trip_complete(p_tenant_id, p_trip_id, p_odometer_end, p_actual_gallons, p_dest_lat, p_dest_lng)` returns void | Exists with all 6 params | V21_00_3 already passes `p_dest_lat`/`p_dest_lng` | ✅ Match — no change |
| 9 | `fuel_pending_set_trip(p_tenant_id, p_pending_id, p_trip_id)` returns void | Exists; not called directly in V21_00_3 (handled via state) | N/A | ✅ Design intentional |
| 10 | Active-trip resumption | `C.enterHaulerMode → C.navTrip(activeTripId)` bypasses `renderHaulerStart` — by design | rancho_origin shown on Overview tab from `trip_driver_view.rancho_origin` (now exposed) | ✅ Design intentional |

## Patches applied

### A) DB — `fleet.trip_driver_view` recreated to include `rancho_origin`
- Migration name: `v21_00_4_trip_driver_view_add_rancho`
- Status: **APPLIED**
- Verification: `rancho_origin` now appears in `information_schema.columns` for `fleet.trip_driver_view`. AR/pay/legal columns remain excluded (audit boundary intact).

### B) Code — 3 `submit_maintenance_event` call sites rewritten
Old (wrong) → New (matches DB):
```diff
- p_pending_id: pendingId, p_driver_id: ..., p_vehicle_id: ...,
- p_event_type: type, p_notes: notes || null, p_occurred_at: new Date().toISOString()
+ p_maintenance_id: pendingId,
+ p_driver_id: ..., p_vehicle_id: ...,
+ p_event_date: new Date().toISOString().slice(0,10),
+ p_service_category: type,
+ p_description: notes || null,
+ p_odometer_reading: null,
+ p_parts_cost: null,
+ p_photo_url: null,
+ p_notes: notes || null
```

Sites patched:
- Line 14346 — chofer (driver tab) Maintenance Submit
- Line 14411 — `flushQueue()` offline-replay path
- Line 14949 — hauler Trip Detail Maint tab submit

Mapping decisions:
- `pendingId / uuid()` → `p_maintenance_id` (same value, correct param name)
- `event_type` ("oil_change"/"tire"/"other") → `p_service_category` (DB stores as service category text)
- `notes` → both `p_description` and `p_notes` (description is the headline, notes is freeform — same content for now)
- `p_event_date` → today's ISO date (YYYY-MM-DD)
- `p_odometer_reading`, `p_parts_cost`, `p_photo_url` → null (UI doesn't capture these yet)
- `p_occurred_at` → dropped (DB has no such param; replaced by `p_event_date`)

### C) APP_VERSION bumped
`V21_00_3` → `V21_00_4`

## Verification gates

| Gate | Result |
|---|---|
| `node --check` on extracted inline JS | ✅ PASS (4 blocks, 787,922 chars, zero errors) |
| `APP_VERSION = 'V21_00_4'` present | ✅ PASS |
| `submit_maintenance_event` calls use `p_maintenance_id` (3×) | ✅ PASS (5 occurrences of `p_maintenance_id`; 2 remaining `p_pending_id:` are in fuel-receipt code which is a different RPC with that real param name) |
| `rancho_origin` still present in code | ✅ PASS (11 occurrences) |
| 6 `V21_00_4:` markers for searchability | ✅ PASS |
| `fleet.trip_driver_view.rancho_origin` exists in DB | ✅ PASS |
| AR/pay/legal columns still excluded from `trip_driver_view` | ✅ PASS (queried; only `rancho_origin` matched our probe set) |
| Filename is `index_V21_00_4.html` (not `index.html`) | ✅ PASS |

## Files produced

- `/home/user/workspace/v21_00_3_build/index_V21_00_4.html` (15,316 lines)
- `/home/user/workspace/v21_00_3_build/V21_00_4_PATCH_REPORT.md` (this file)

## DB migrations applied (in this batch)

1. `v21_00_4_trip_driver_view_add_rancho` — recreates `fleet.trip_driver_view` with `rancho_origin` exposed

## Remaining design decisions (not defects)

- **Q9** — `fuel_pending_set_trip` indirect call pattern: existing `wireFuelControls()` reads `C.state.haulerFuelTripId`. If the trip-stamping is missing for hauler-context fuel receipts, that's a separate feature to add. Out of scope for V21_00_4.
- **Q10** — Active-trip resumption is by-design; rancho_origin now flows through `trip_driver_view`.

## Supersedes

This patches V21_00_3 only — does NOT replace it. V21_00_3 remains a valid intermediate version. V21_00_4 is the recommended deploy target.
