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
