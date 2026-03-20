# Mottainai Survey App — Bug Fix TODO (v3.2.20)

## Root Causes Identified

### BUG 1 — Polygon tap detection broken (crash + no response)
- [ ] `_onPolygonTap()` reads `_polygonHitNotifier.value` AFTER the GestureDetector fires,
  but flutter_map v7 clears the hitNotifier value asynchronously. By the time the callback
  runs the value is already null → tap silently swallowed.
  FIX: Use `MouseRegion`/`GestureDetector` with `onTapDown` to capture the hitNotifier value
  at the moment of the tap, not in a deferred callback. Switch to the flutter_map v7
  `PolygonLayer` `onTap` callback pattern instead of the external GestureDetector wrapper.

### BUG 2 — Labels disappear after first _rebuildOverlays call
- [ ] `_fetchCustomerNamesForPolygons()` calls `_rebuildOverlays()` inside a loop for each
  polygon (up to 30 API calls). Each call to `setState()` inside `_rebuildOverlays` triggers
  a rebuild, but the `_capturedLabels` list is replaced with a new list that only contains
  labels for polygons processed SO FAR in the loop. The final setState wins, but if the
  widget rebuilds in between, labels from earlier iterations are lost.
  FIX: Collect ALL customer names first (complete the loop), THEN call _rebuildOverlays once.

### BUG 3 — App crash: `_polygonHitNotifier.dispose()` called while still in use
- [ ] `_polygonHitNotifier` is a `ValueNotifier<LayerHitResult<String>?>` passed to
  `PolygonLayer`. If the widget is disposed while an async operation (polygon sync) is
  still running and calls setState, the notifier is already disposed → crash.
  FIX: Add `if (!mounted) return` guards before every setState in async methods.
  Also guard _rebuildOverlays with a mounted check.

### BUG 4 — Building ID labels always hidden behind IgnorePointer but also behind polygon fill
- [ ] Building ID labels use `IgnorePointer` (correct — so taps pass through to polygon),
  but `MarkerLayer` is rendered ABOVE `PolygonLayer` in the stack. However the label
  `Marker` width=90 height=16 is too small for the text at zoom 16 and gets clipped.
  Also the `Text` widget inside the Marker has no `Material` ancestor so shadows may
  not render correctly on some devices.
  FIX: Wrap label Text in a proper Container with explicit background, increase marker
  height to 20, and ensure the label layer is always above the polygon layer.

## Fixes to Apply
- [x] Fix 1: Replace GestureDetector+hitNotifier pattern with flutter_map v7 PolygonLayer onTap
- [x] Fix 2: Batch customer name fetching — call _rebuildOverlays once after all names loaded
- [x] Fix 3: Add mounted guards to all async setState calls
- [x] Fix 4: Fix label marker sizing and rendering
- [x] Fix 5: Bump DB version to 12 to force cache clear on devices with old cached data
- [x] Fix 6: Bump app version to 3.2.20

## v3.2.21 — Tile Layer Fix (blank grey map)
- [x] Add fallbackUrl (OpenStreetMap) to satellite TileLayer
- [x] Add errorTileCallback to suppress tile errors silently
- [x] Add panBuffer: 0 to reduce tile requests on slow connections
- [x] fallbackUrl handles retry automatically (no extra package needed)
- [x] Bump version to 3.2.21

## v3.2.22 — Map Layout Fix (blank grey, infinite scroll)
- [x] Found: EnhancedLocationMap inside ListView with no height constraint
- [x] Wrapped in SizedBox(height: MediaQuery * 0.45) in pickup_form_screen_v2.dart
- [x] Root cause was ListView giving unbounded height — fixed with SizedBox
- [x] Bump version to 3.2.22

## v3.2.23 — Architecture Redesign (crash on load, progressive rendering)

### Root Causes Identified
- [x] CRASH 1: _rebuildOverlays() calls jsonDecode on 1000 polygon geometries on the UI thread
        → Decoding 1000 JSON geometry strings synchronously in setState() blocks the UI thread
        → On low-end devices this causes ANR (Application Not Responding) → crash
        FIX: Move all geometry decoding to a compute() isolate (background thread)

- [x] CRASH 2: _fetchCustomerNamesForPolygons makes up to 30 sequential HTTP API calls
        before _rebuildOverlays is called. Each call is awaited serially.
        On slow networks this takes 30–90 seconds, during which the widget is
        in a half-initialised state. If the user navigates away, setState crashes.
        FIX: Run customer name fetches in parallel (Future.wait) with a timeout,
        and decouple them from the initial render — show polygons first, names later.

- [x] CRASH 3: _initializeLocation → _loadPolygonsForCurrentLocation → _syncPolygons
        is a 3-deep async chain with no isolate separation. All DB reads, JSON decoding,
        and HTTP calls run on the main isolate. On 1000-building datasets this is fatal.
        FIX: Separate into 3 independent phases with UI updates between each.

- [x] PERF 1: The app fetches up to 1000 polygons (safety cap) but renders ALL of them
        at once. flutter_map v7 PolygonLayer with 1000 polygons + 2000 markers is
        extremely heavy. On low-end devices this causes jank and OOM crashes.
        FIX: Viewport-based rendering — only render polygons visible in the current
        map bounds. Use map camera position listener to update visible set.

- [x] PERF 2: cachePolygons() does 2 DB operations per polygon (delete + insert) in a
        batch. For 1000 polygons this is 2000 batch operations. SQLite on Android
        can handle this but it is slow. Use INSERT OR REPLACE instead.
        FIX: Use INSERT OR REPLACE (UPSERT) in cachePolygons().

### Fixes to Apply
- [x] Fix A: Move geometry decoding to compute() isolate
- [x] Fix B: Parallel customer name fetches with Future.wait + 5s timeout per call
- [x] Fix C: 3-phase progressive loading: (1) show map immediately, (2) load cache, (3) sync in background
- [x] Fix D: Viewport-based polygon rendering (only render visible polygons)
- [x] Fix E: INSERT OR REPLACE for polygon cache upsert
- [x] Fix F: Bump version to 3.2.23

## v3.2.24 — Polygon Tap Fix + GPS Centering Fix

- [x] Fix polygon tap detection (tapping polygon does nothing)
- [x] Fix GPS location pin not centred precisely on user's position
- [x] Bump version to 3.2.24

## v3.2.25 — Crash Fix
- [x] Diagnose crash source in v3.2.24 — isolate-unsafe custom classes in compute()
- [x] Fix: return plain List<Map> from compute(), reconstruct LatLng on main thread
- [x] Bump version to 3.2.25
