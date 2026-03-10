# Changelog

All notable changes to the Mottainai Survey App will be documented in this file.

## [3.2.11] - 2026-03-10

### Fixed
- **Map camera not centering on GPS location (CRITICAL)**: Polygons and labels appeared at wrong position
  - Root cause: `mapController.move()` was called before FlutterMap controller was ready (race condition)
  - Fix: added `onMapReady` callback to FlutterMap; GPS location is stored as `_pendingCenter` and applied as soon as the map is ready
  - If GPS is obtained before map is ready, the pending center is applied in `onMapReady`
  - If map is ready before GPS, `move()` is called immediately when GPS resolves

---

## [3.2.10] - 2026-03-10

### Fixed
- **Map not centering on GPS location**: Map camera now reliably centers on GPS location when the pickup form opens
  - Root cause: `addPostFrameCallback` fired before FlutterMap was fully mounted, so `mapController.move()` was ignored
  - Fix: replaced with `Future.delayed(300ms)` to ensure the map widget is ready before moving
  - Added a second re-center call after polygons finish loading
- **Longitude bounding box formula incorrect**: Cache query was returning buildings from a 13× wider area than intended
  - Root cause: formula used `lat/90` instead of `cos(lat)` for longitude delta — at Lagos (6.58°) this gave ±6.9km instead of ±0.5km
  - Fix: corrected to `radiusKm / (111.0 * cos(lat))` using `dart:math`
- **Search radius increased from 500m to 1km**: 500m was too tight; buildings at the edge of the user's block were excluded
- **Database upgraded to v10**: old polygon cache cleared on first launch to force re-sync with correct parameters
- **ArcGIS safety cap increased from 500 to 1000 buildings** for 1km radius coverage

---

## [3.2.9] - 2026-03-10

### Fixed
- **Polygon overlays not visible and not tappable**: Building polygons were cached but not rendered on the map
  - Root cause 1: Polygon overlays were rebuilt on every `build()` call with 600 JSON decodes — UI thread froze, preventing render
  - Root cause 2: Cache query used 5km radius but sync only fetched 500m, so cache returned buildings from wrong area
  - Root cause 3: Customer label API was called for all 600 buildings simultaneously, causing server overload and app crash
  - Fix: Polygon overlays are now pre-built and stored in state (`_polygonOverlays`, `_polygonLabels`), rebuilt only when data changes
  - Fix: Cache query radius aligned to 500m to match sync radius
  - Fix: Customer label fetching limited to the 20 nearest buildings
  - Fix: Map now centers on user GPS location on open via `_mapController.move()` in `addPostFrameCallback`

---

## [3.2.8] - 2026-03-10

### Fixed
- **Polygon coordinates in wrong projection (CRITICAL)**: Building polygons were being drawn ~80km away from actual buildings
  - Root cause: ArcGIS service stores data in a local Nigerian projection (not standard Web Mercator). The old conversion formula produced wrong coordinates (e.g. lat=7.35, lon=3.88 instead of lat=6.58, lon=3.35)
  - Fix: added `outSR=4326` to all ArcGIS queries — server now returns WGS84 (lon, lat) directly, no client-side conversion needed
  - Removed the incorrect `webMercatorToWGS84()` conversion from `BuildingPolygon.fromArcGIS()`
  - Database upgraded to v9; existing cached polygons with wrong coordinates are cleared automatically on first launch
  - Polygons now render correctly on the satellite map and tap detection works

---

## [3.2.7] - 2026-03-10

### Fixed
- **ArcGIS Connection Abort on Mobile (CRITICAL)**: Fixed "Software caused connection abort" error
  - Root cause: the ArcGIS dataset has 1.5 million features; a 5km radius query returns thousands of polygon geometries in one response, which mobile connections cannot sustain
  - **Default radius reduced from 5km to 500m** — enough to cover the immediate work area
  - **Paginated fetching**: results are now fetched in pages of 100 records using `resultRecordCount` + `resultOffset`
  - **30-second timeout** added to all ArcGIS HTTP requests
  - **Safety cap** of 500 buildings prevents memory issues on low-end devices
  - Partial results are preserved if a page fails mid-pagination

---

## [3.2.6] - 2026-03-10

### Fixed
- **ArcGIS Building Cache Always Empty (CRITICAL)**: Fixed "Cannot perform query. Invalid query parameters" error
  - Root cause: missing `inSR=4326` parameter in the spatial query
  - ArcGIS requires `inSR` to know the coordinate system of the input geometry (WGS84)
  - Without it, ArcGIS rejects the query entirely, leaving the building cache at "0 buildings • Never"
  - Also removed the unnecessary API token from all queries — the service is public
  - Building polygons will now load correctly when opening the pickup form

---

## [3.2.5] - 2026-03-10

### Added
- **Customer Contact Fields**: Added `customerName`, `customerPhone`, `customerEmail`, and `customerAddress` fields to the pickup form
  - `customerName`, `customerPhone`, and `customerAddress` are required fields
  - `customerEmail` is optional
  - Fields are now properly sent to the backend in the multipart form submission
  - SQLite database upgraded to v8 with migration to add new columns

### Fixed
- **Backend Submission Failure (CRITICAL)**: Fixed root cause of all pickup submissions failing to sync
  - `customerName` was being sent as the hardcoded string `"default_form_id"` instead of the actual customer name
  - Backend was rejecting submissions with this invalid value
  - Now sends the actual customer name entered in the form
  - Verified working: backend returns `{"status":"success"}` with correct customer data

### Changed
- Pickup form reorganized into sections: Customer Details, Pickup Details, Location, Photos, Notes
- Section headers added for improved readability

---

## [3.2.4] - 2025-12-02

### Fixed
- **Sync Status Display Bug**: Fixed issue where pickups showed as "Pending" in history screen even after successful sync to backend
  - Added automatic history reload when sync completes
  - History screen now listens for sync completion and refreshes pickup list
  - Users now see correct "Completed" status immediately after sync
  - No backend changes required - display issue only
  - Files modified: `lib/screens/history_screen.dart`

### Technical Details
- Root cause: History screen wasn't reloading after background sync completion
- Solution: Added `SyncProvider` listener to history screen that triggers reload when `isSyncing` changes to `false`
- Impact: Improved user experience, reduced confusion about sync status
- See `MOBILE_APP_SYNC_BUG_FIX.md` for detailed analysis

---

## [3.2.3] - 2025-11-28

### Added
- Offline support for pickup submissions
- Local SQLite database for storing pickups when offline
- Automatic sync when internet connection is restored
- Manual sync via pull-to-refresh in history screen
- Connectivity status indicator on home screen

### Changed
- Improved photo upload handling (supports up to 50MB per photo)
- Enhanced error messages for failed submissions
- Updated backend API integration

### Fixed
- Photo upload failures on slow connections
- Token refresh issues
- Building ID validation

---

## [3.2.0] - 2025-11-26

### Added
- Company and operational lot selection
- PIN-based company authentication
- Webhook-based routing for different companies
- Socio-economic class selection for residential customers
- Enhanced pickup form with all required fields

### Changed
- Redesigned pickup form UI
- Improved map integration for location selection
- Better photo capture workflow

---

## [3.1.0] - 2025-11-20

### Added
- QR code scanner for building IDs
- Incident reporting field
- GPS location capture
- Photo capture for before/after pickup

### Changed
- Updated backend API endpoints
- Improved authentication flow

---

## [3.0.0] - 2025-11-15

### Added
- Initial release with offline support
- User authentication
- Pickup submission form
- Photo uploads
- History screen

---

## Version History

- **v3.2.8** (Mar 10, 2026) - Polygon coordinate projection fix
- **v3.2.7** (Mar 10, 2026) - ArcGIS connection abort fix (pagination + 500m radius)
- **v3.2.6** (Mar 10, 2026) - ArcGIS invalid query parameters fix (inSR=4326)
- **v3.2.5** (Mar 10, 2026) - Customer contact fields + backend submission fix
- **v3.2.4** (Dec 2, 2025) - Sync status display fix
- **v3.2.3** (Nov 28, 2025) - Offline support and auto-sync
- **v3.2.0** (Nov 26, 2025) - Company selection and PIN auth
- **v3.1.0** (Nov 20, 2025) - QR scanner and GPS
- **v3.0.0** (Nov 15, 2025) - Initial release
