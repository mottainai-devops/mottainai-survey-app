# Mottainai Survey App — Integration State

**Last Updated:** 2026-03-10  
**Current Version:** 3.2.18+1 (versionCode: 1, versionName: 3.2.18)  
**Build Status:** ✓ Clean (analyze passes, release APK confirmed v3.2.18)

---

## 1. What Is Working

| Feature | Status | Notes |
|---|---|---|
| App installs and launches | ✓ Working | v3.2.18 confirmed via App Info |
| GPS location detection | ✓ Working | Lat/Lon displayed correctly below map |
| Satellite tile layer | ✓ Working | ESRI World Imagery renders correctly |
| ArcGIS sync (network) | ✓ Working | 90s timeout, 50-record pages, 2 retries |
| Sync progress indicator | ✓ Working | Shows "Syncing buildings... (N fetched)" |
| Building cache (SQLite) | ✓ Working | 150+ buildings cached after sync |
| Polygon overlay count | ✓ Working | `overlays:N` debug badge shows correct count |
| Pickup form fields | ✓ Working | customerName, customerPhone, customerAddress |
| Form submission | ✓ Working | Customer name no longer sent as "default_form_id" |
| Build version embedding | ✓ Fixed | `build.gradle` now uses `flutter.versionName/versionCode` |

---

## 2. Outstanding Issues — Map Polygon Layer

### Issue A: Polygons Rendered Far From GPS Location

**Symptom:** 148–600 polygon overlays are built (confirmed by `overlays:N` badge) but they appear hundreds of metres away from the red GPS pin. The satellite imagery under the pin shows buildings with no polygon outlines.

**Root Cause Analysis:**

The ArcGIS sync fetches buildings within 1 km of the GPS location. However, the **bounding box cache query** (`getCachedPolygonsNearLocation`) returns buildings from the previous sync session, which may have been centred at a different GPS point. The 7-day staleness check passes, so no re-sync is triggered even when the user is at a new location.

**Fix Attempted (v3.2.18):** Added `SharedPreferences`-based sync centre tracking. If the current GPS is more than 300 m from the last sync centre, a re-sync is triggered automatically. Database bumped to v11 to clear stale cache on upgrade.

**Why Still Failing:** The v3.2.18 APK that was distributed still had `versionCode=32, versionName=3.2.12` hardcoded in `build.gradle`. Android treated it as the same version as the already-installed v3.2.12 and did not upgrade the app data (including the database). The fix to `build.gradle` was only applied in the final build (commit `5093b9e`). The user needs to **uninstall and reinstall** the latest APK for the database migration (v11) to run.

**Pending Action:** Confirm with user whether v3.2.18 (genuine, versionCode=1) was installed fresh after uninstall. If yes, the issue is deeper — the ArcGIS dataset may simply not have building footprints at the user's exact GPS coordinates, or the coordinate projection is still incorrect.

**Next Steps When Resuming:**
1. Add a diagnostic screen or log dump showing the first 3 cached polygon centre coordinates so we can verify they match the GPS location.
2. Test the ArcGIS query directly from the device's network to confirm buildings are returned at the correct coordinates.
3. Consider switching from `getCachedPolygonsNearLocation` (bounding box) to a direct ArcGIS query on every map open (no local cache), to eliminate cache staleness entirely.

---

### Issue B: Polygon Tap Popup Not Firing

**Symptom:** Tapping directly on a polygon does not open the building info popup. Only tapping the label badge (for captured buildings) opens a popup.

**Root Cause Analysis:**

In flutter_map v7, the `PolygonLayer` renders on a `Canvas` — it is not a standard Flutter widget tree element. The `GestureDetector` wrapping the `PolygonLayer` uses `hitNotifier` (a `LayerHitNotifier<String>`) to detect which polygon was tapped. However, the `MarkerLayer` (which renders label badges) sits above the `PolygonLayer` in the widget tree and uses `GestureDetector(behavior: HitTestBehavior.opaque)` internally, which consumes all tap events before they reach the polygon layer.

**Fix Attempted (v3.2.17):** Migrated to flutter_map v7 native hit detection API (`hitNotifier`, `hitValue`). Added `IgnorePointer` to label markers so taps pass through to the polygon below.

**Why Still Failing:** The `IgnorePointer` wrapping the label `GestureDetector` prevents the label tap from working too, but the polygon tap still doesn't fire. The `GestureDetector` wrapping `PolygonLayer` may not be receiving events because `FlutterMap` itself intercepts map pan/zoom gestures first.

**Pending Action (requires API contract):** The backend API contract will clarify what data is needed for the building info popup. Once the contract is received, we will redesign the tap interaction using flutter_map's `MapEventTap` stream (via `mapController.mapEventStream.listen`) instead of a `GestureDetector`, which avoids the gesture conflict entirely.

---

### Issue C: No Labels for Captured Buildings

**Symptom:** Buildings that have been previously captured (have customer records) do not show a green name badge above their polygon.

**Root Cause Analysis:**

The `_rebuildOverlays` method calls `_customerLabelsCache` to look up captured buildings by `buildingId`. This cache is populated by `_loadCustomerLabels()`, which queries the local SQLite database for existing pickups. However, if the polygon cache and the pickup records use different building ID formats (e.g., `"9439 LASIKA06 006"` vs `"9439LASIKA06006"`), the lookup will always return null and no label will be shown.

**Pending Action:** Requires the backend API contract to confirm the canonical building ID format used in pickup submissions. Once confirmed, normalise the ID comparison in `_loadCustomerLabels()`.

---

## 3. Outstanding Issues — Property Enumeration

**Symptom:** (Details to be provided by user — noted as "there's an issue too in the property enumeration.")

**Pending Action:** User to describe the specific enumeration issue. Backend developer to share the Joint API Contract which will clarify the expected data model for property enumeration.

---

## 4. Pending: Backend Joint API Contract

The backend developer will share the **Joint API Contract** which is expected to cover:

- Canonical building ID format
- Property enumeration endpoint(s) and data model
- Customer/pickup submission payload schema
- Any authentication changes

**Action on Receipt:** Review the contract, update `integration_state.md` with the agreed schema, then implement the required changes in the app.

---

## 5. Version History (v3.2.4 → v3.2.18)

| Version | Key Change |
|---|---|
| v3.2.4 | Baseline (as provided by user) |
| v3.2.5 | ArcGIS `inSR=4326` fix — coordinates now in WGS84 |
| v3.2.6 | Coordinate projection fix — buildings no longer 80 km off |
| v3.2.7 | Pickup form customer fields added |
| v3.2.8 | Form submission bug fixed (customerName was "default_form_id") |
| v3.2.9 | First polygon overlay rendering attempt |
| v3.2.10 | Longitude bounding box formula corrected (`cos(lat)`) |
| v3.2.11 | Map centering race condition fixed (`onMapReady` callback) |
| v3.2.12 | Initial zoom set to 16 for building-level detail |
| v3.2.13 | `simplificationTolerance: 0`, debug overlay, `withValues` API |
| v3.2.14 | All analyzer warnings resolved |
| v3.2.15 | Unused imports removed — clean build |
| v3.2.16 | ArcGIS timeout increased to 90 s, retry logic, progress indicator |
| v3.2.17 | flutter_map v7 `hitNotifier` polygon tap, label logic for captured buildings |
| v3.2.18 | Location-aware re-sync (300 m threshold), DB v11, `build.gradle` version fix |

---

## 6. Files Most Relevant to Outstanding Issues

| File | Issue |
|---|---|
| `lib/widgets/enhanced_location_map.dart` | All three map issues (A, B, C) |
| `lib/services/arcgis_service.dart` | Issue A — sync radius and coordinate correctness |
| `lib/services/polygon_cache_service.dart` | Issue A — bounding box cache query |
| `lib/database/database_helper.dart` | Issue A — DB schema and migrations |
| `lib/screens/pickup_form_screen_v2.dart` | Property enumeration issue |
| `android/app/build.gradle` | Version embedding (now fixed) |
