# Merge Report: V21_00_2 — Hauler + Multi-Rancho + Stacked-Daywork

**Output file:** `index_V21_00_2.html`
**Date:** 2026-06-09
**Base:** `PROD_V21_00_1.html` (14,131 lines — current prod with hauler module)
**Sources of patches:**
- `V20_193_base.html` (17,578 lines) — stacked-Daywork PDF logic
- `V20_194_multirancho.html` (18,204 lines) — multi-rancho patches (source of 16 patches)
**Result:** `index_V21_00_2.html` (14,728 lines, 847 KB, +597 lines from base)
**JS syntax:** `node --check` on extracted JS → exit code 0 (zero syntax errors)

---

## What Was Merged

### PHASE 2A — Version Bump
- `window.APP_VERSION = 'V21_00_1'` → `'V21_00_2'`
- Added `console.log('[V21_00_2] hauler + multi-rancho + stacked-Daywork merged');`

### PHASE 2B — Stacked-Daywork PDF (ported from V20_193)

**Why needed:** V21_00_1's `buildPDFWindow` was based on a codebase that predates V20_183/V20_193's Daywork PDF fix. Serafín reported that Daywork workers' Entrada/Salida cells showed blank in the PDF when there were multiple shifts.

**What was ported (2 code regions inside `buildPDFWindow`):**

1. **Section 1** — Daywork bypass in the `actCols` shift-collection loop (lines ~6392–6431 in output):
   - Before the inner `for(var wi3_...)` loop, added a Daywork guard that collects real shift times into `_col._dwShifts[]`, pushes a single synthetic empty shift, and `continue`s (skips the subdivision logic entirely)
   - **Adaptation:** V20_193 uses `_colMatchesWAct()` helper; V21_00_1 uses direct `esName/tipo/finca` comparison. The ported code uses V21_00_1's existing matching approach for compatibility.

2. **Section 2** — Daywork stacked rendering in the trEntry/trExit loop (lines ~6912–6927 in output):
   - If `col4.payType==='Daywork' && col4._dwShifts && col4._dwShifts.length`, renders all real shifts stacked with `<br>` separators in a single cell instead of the blank-cell path.

3. **buildPDFWindow console.log** — `'[V21_00_2] buildPDFWindow called — stacked-Daywork active'`

### PHASE 2C — All 16 V20_194 Multi-Rancho Patches

| Patch | Description | Status |
|-------|-------------|--------|
| PATCH 3 | Ranch-pill CSS (13 rules) | ✅ Applied |
| PATCH 4 | `ranchDupOv` modal HTML | ✅ Applied |
| PATCH 5 | `ranchesSection` HTML in pg=0 | ✅ Applied |
| PATCH 6 | Multi-rancho buttons in Resumen (renamed + 2 new) | ✅ Applied |
| PATCH 7 | Multi-rancho data layer (~370 lines): `_ranchos`, `_activeRanchoIdx`, `MAX_RANCHOS`, `_saveRanchoCtx`, `_loadRanchoCtx`, `_renderActiveRanchoUI`, `switchRancho`, `_isRanchoDuplicado`, `_initRanchos`, `renderRanchBar`, `populateRanchAddSel`, `onPillClick`, `addRanchBlock`, `removeRanchBlock`, `syncRanchConfigToParams` | ✅ Applied |
| PATCH 8 | `resetState()` resets `_ranchos=[]`, `_activeRanchoIdx=0` | ✅ Applied |
| PATCH 9 | `_persistState` includes `_ranchos` + `_activeRanchoIdx` in localStorage; calls `_saveRanchoCtx` before serializing | ✅ Applied |
| PATCH 10 | `load()` migration: restores `_ranchos`/`_activeRanchoIdx` from storage or falls back to `_initRanchos()` | ✅ Applied |
| PATCH 11 | `_enterReadOnly` includes `_ranchos`/`_activeRanchoIdx` in `_localBackup` | ✅ Applied |
| PATCH 12 | `exitReadOnly` restores `_ranchos`/`_activeRanchoIdx` from `_localBackup`; calls `renderRanchBar()` | ✅ Applied |
| PATCH 13 | `loginSuccess` calls `renderRanchBar()` after `load()` | ✅ Applied |
| PATCH 14 | `genPDFAllRanchos()` function — generates separate PDF per rancho with 500ms delay | ✅ Applied |
| PATCH 15 | `sendAllRanchosToSheets()` function — sequential send with 2s delay + unique frameId per rancho | ✅ Applied |
| PATCH 16 | `sendToSheets(customFrameId)` — accepts optional frameId for multi-rancho calls | ✅ Applied |

**Note on PATCH 9:** V21_00_1 does not have `_dayFlow` (that's a V20_91_01 feature from V20_193 only). The `_persistState` port adds `_ranchos` and `_activeRanchoIdx` but does NOT add `df:_dayFlow` — this is intentional and correct for the V21 base.

**Note on PATCH 15 (sendAllRanchosToSheets):** Inserted before `loadSheetsData()` function (alternate anchor — V21_00_1 doesn't have the exact V20_194 comment anchor). Functionality is identical.

### PHASE 2D — NEW: Hauler Trips Track Rancho of Origin

This is the new feature linking hauler trips to the rancho they're hauling from.

**1. Hauler start screen UI** (`renderHaulerStart` function):
- Added `<select id="haulerStartRancho">` labeled "Rancho de origen"
- Populated dynamically from `window._ranchos[]` (the surquero's active rancho list)
- Rendered as the first field before Origin/Destination/Customer
- Required field — validation prevents trip creation if not selected

**2. Trip-creation logic** (button onclick handler in `renderHaulerStart`):
- Reads selected value from `haulerStartRancho` before calling `C.startHaulingTrip()`
- Shows error message via `haulerStartErr` if not selected (using i18n key `ranchoRequired`)
- Passes `rancho_origin` in the opts object

**3. `startHaulingTrip` RPC call:**
- Added `p_rancho_origin: opts.rancho_origin || null` to the `start_hauling_trip` RPC payload

**4. Trip detail display** (`drawTripDetail` function):
- Added `infoRow(t('ranchoOrigen'), trip.rancho_origin || null)` in the Load Info card, as the first row

**5. i18n keys added** (Spanish + English):
```js
ranchoOrigen:   {es:'Rancho de origen',             en:'Ranch of origin'},
selRancho:      {es:'— Selecciona un rancho —',     en:'— Select a ranch —'},
ranchoRequired: {es:'Selecciona el rancho de origen antes de iniciar.',
                 en:'Please select the ranch of origin before starting.'}
```

**6. All new lines prefixed with** `// V21_00_2: hauler-rancho linkage`

**SQL schema files** (written, NOT applied):
- `hauling_trips_rancho_origin_migration.sql` — idempotent `ADD COLUMN IF NOT EXISTS rancho_origin TEXT`
- `hauling_trips_rancho_origin_rollback.sql` — `DROP COLUMN IF EXISTS rancho_origin`

---

## Verification Checklist

- [x] File ends with `</script></body></html>` (structure intact)
- [x] `window.APP_VERSION === 'V21_00_2'`
- [x] `_ranchos` present (83 occurrences)
- [x] `renderRanchBar` present (7 occurrences)
- [x] `_saveRanchoCtx` present (6 occurrences)
- [x] `_loadRanchoCtx` present (7 occurrences)
- [x] `genPDFAllRanchos` present (3 occurrences)
- [x] `sendAllRanchosToSheets` present (2 occurrences)
- [x] `ranchBlockList` present (4 occurrences)
- [x] `MAX_RANCHOS` present (4 occurrences)
- [x] `switchRancho` present (3 occurrences)
- [x] `_isRanchoDuplicado` present (4 occurrences)
- [x] Hauler symbols preserved: `hauler` 39 occurrences (up from 36 — new code added), `clock_in` 5, `restoreClock` 5
- [x] `V21_00_1 — Hauler mode` block intact
- [x] `_dwShifts` present (5 occurrences)
- [x] `APILADOS` present (1 occurrence — in comment)
- [x] `haulerStartRancho` element present (2 occurrences)
- [x] `rancho_origin` referenced in trip code (3 occurrences)
- [x] `sheetsAllBtn` and `pdfAllBtn` present with `display:none`
- [x] `ranchDupOv` modal present
- [x] `ranchEmptyState` present
- [x] `_localBackup` includes `_ranchos` (V64 FIX 1)
- [x] `exitReadOnly` restores `_ranchos` + calls `renderRanchBar`
- [x] `_persistState` saves `_ranchos` to localStorage
- [x] `load()` migrates legacy format → `_ranchos[0]`
- [x] `resetState()` clears `_ranchos=[]`
- [x] `node --check` on extracted JS → exit code 0 (zero syntax errors)
- [x] No `epsilon` or `[TEST]` markers leaked
- [x] All V20_194 references are in comments only (22 comment refs — code provenance)
- [x] `PROD_V21_00_1.html` untouched (working copy used)
- [x] `V20_193_base.html` untouched
- [x] `V20_194_multirancho.html` untouched

---

## Conflicts Encountered and Resolutions

### 1. `_colMatchesWAct` missing in V21_00_1 (stacked-Daywork port)

**Conflict:** V20_193's stacked-Daywork code uses `_colMatchesWAct(col, act)` helper which doesn't exist in V21_00_1's `buildPDFWindow`. V21_00_1 uses direct `esName/tipo/finca` comparison.

**Resolution:** The Daywork bypass section was ported using V21_00_1's existing `esName/tipo/finca` matching pattern instead of `_colMatchesWAct`. Functionally equivalent — both check the same three fields.

### 2. `_dayFlow` absent from V21_00_1 (PATCH 9 _persistState)

**Conflict:** V20_194's `_persistState` includes `df:_dayFlow` in the localStorage object. V21_00_1 does not have `_dayFlow` (introduced in V20_91_01).

**Resolution:** Ported only `_ranchos` and `_activeRanchoIdx` additions; did NOT add `_dayFlow`. This is correct — V21_00_1 doesn't initialize `_dayFlow` anywhere and adding it would introduce an undefined variable reference.

### 3. PATCH 15 insertion anchor

**Conflict:** V20_194 has a `// ── GROUP ACTIVITY SYSTEM` comment as the anchor. V21_00_1 uses a different code structure around `loadSheetsData`.

**Resolution:** `sendAllRanchosToSheets` was inserted just before the `loadSheetsData()` function — functionally equivalent position.

### 4. `haulerStartRancho` selector populated from `_ranchos`

**Design decision:** The rancho selector reads from `window._ranchos[]` at the time `renderHaulerStart()` is called. This means the hauler sees whatever ranchos the logged-in surquero has configured for the day. If no ranchos are configured (e.g., single-rancho legacy flow), the dropdown will be empty except for the placeholder, and the driver cannot start without selecting one.

**Mitigation:** Consider whether the hauler flow needs a fallback when `_ranchos` is empty (e.g., allow free-text entry). Flagged as open question #1.

---

## Open Questions for Serafín / Cyndy

1. **Hauler rancho selector when surquero has no ranchos configured:** If `_ranchos[]` is empty (legacy single-rancho day), the `haulerStartRancho` dropdown shows only the placeholder and the driver cannot proceed. Should we fall back to showing the main `#rancho` field value as the only option? Or allow a free-text input?

2. **RPC `start_hauling_trip` signature:** The migration adds `p_rancho_origin` to the RPC call. If the Supabase function `start_hauling_trip` is defined without this parameter, the extra field will cause a Supabase error or be silently ignored depending on the RPC definition. Cyndy needs to update the Supabase function signature to accept `p_rancho_origin TEXT DEFAULT NULL` when applying the migration.

3. **`rancho_origin` in trip list / hauler dashboard:** The MERGE_BRIEF mentions adding `rancho_origin` as a column in the trip list if one exists. V21_00_1's hauler module navigates directly to the trip detail — there is no separate trip list screen. If a trip list is added in a future version, `rancho_origin` should be added as a column there.

4. **Multi-rancho `renderRanchBar` visibility for non-admin haulers:** The `renderRanchBar` function hides `ranchesSection` for non-admin users. Hauler mode is driver-only (not a surquero admin). If haulers ever need to manage ranchos, this needs reconsideration.

5. **`_dayFlow` in V21_00_1:** V21_00_1 does NOT have `_dayFlow` (the daily clock-in/out flow state machine from V20_91_01). If V21_00_2 is ever merged back to a V20_193+ base, `_dayFlow` must be reconciled.

---

## File Inventory

| File | Status |
|------|--------|
| `index_V21_00_2.html` | ✅ Created (14,728 lines, 847 KB) |
| `V21_00_2_MERGE_REPORT.md` | ✅ Created |
| `hauling_trips_rancho_origin_migration.sql` | ✅ Created (NOT applied) |
| `hauling_trips_rancho_origin_rollback.sql` | ✅ Created |
| `PROD_V21_00_1.html` | ✅ Untouched |
| `V20_193_base.html` | ✅ Untouched |
| `V20_194_multirancho.html` | ✅ Untouched |
| `WORKING_V21_00_2.html` | Intermediate working copy (can be deleted) |
