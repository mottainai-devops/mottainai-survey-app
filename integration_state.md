# Mottainai Survey App — Integration State

**Last Updated:** April 9, 2026
**Current Version:** v3.3.3+1 (versionCode: 1, versionName: 3.3.3)
**GitHub Repo:** https://github.com/mottainai-devops/mottainai-survey-app
**Backend API Base:** https://upwork.kowope.xyz
**Latest Build:** Build #80 ✅ (April 9, 2026)
**Build Status:** ✓ Clean — release APK confirmed v3.3.3

> **Consolidation Note (April 9, 2026):** The `mottainaisurvey/old-survey-web-app` repository has been archived and is no longer active. The authoritative backend is `mottainai-devops/mottainai-platform-backend` (https://upwork.kowope.xyz). All integration work targets that repo exclusively.

---

## 1. What Is Working

| Feature | Status | Notes |
|---------|--------|-------|
| App installs and launches | ✓ Working | v3.3.3 confirmed |
| GPS location detection | ✓ Working | Lat/Lon displayed correctly below map |
| Satellite tile layer | ✓ Working | ESRI World Imagery renders correctly |
| ArcGIS sync (network) | ✓ Working | 90s timeout, 50-record pages, 2 retries |
| ArcGIS layer | ✓ Migrated | Now uses `Nigeria_Building_Footprints` |
| Sync progress indicator | ✓ Working | Shows "Syncing buildings... (N fetched)" |
| Building cache (SQLite) | ✓ Working | 150+ buildings cached after sync |
| Polygon overlay count | ✓ Working | `overlays:N` debug badge shows correct count |
| Pickup form fields | ✓ Working | customerName, customerPhone, customerAddress |
| Form submission | ✓ Working | Source tagged `mobile_app` on backend |
| Multi-unit socio-class | ✓ Working | Majority vote composite key (v3.3.1) |
| Companies API URL | ✓ Fixed | Updated from dead IP to upwork.kowope.xyz (v3.3.2) |
| Inline supervisor ID edit | ✓ Working | Stuck unsynced submissions can be corrected (v3.3.3) |
| Build version embedding | ✓ Fixed | `build.gradle` uses `flutter.versionName/versionCode` |
| SMS notifications | ✓ Working | Backend sends Termii SMS on submission |
| Source field tagging | ✓ Working | Backend tags all mobile submissions as `source: 'mobile_app'` |

---

## 2. ArcGIS Layer Migration

**Migration Date:** April 9, 2026
**Old Layer:** `New_Footprints_gdb_b1422`
**New Layer:** `Nigeria_Building_Footprints`

The survey app's ArcGIS sync was already targeting `Nigeria_Building_Footprints` prior to April 9, 2026. The migration is complete and confirmed working. See `mottainai-platform-backend/docs/GIS_LAYER_MIGRATION_NOTICE.md` for full GIS team details.

---

## 3. Outstanding Issues — Map Polygon Layer

### Issue A: Polygons Rendered Far From GPS Location

**Symptom:** Polygon overlays are built but appear hundreds of metres away from the GPS pin.

**Root Cause:** The bounding box cache query (`getCachedPolygonsNearLocation`) returns buildings from the previous sync session. The 7-day staleness check passes, so no re-sync is triggered when the user is at a new location.

**Fix Applied (v3.2.18):** `SharedPreferences`-based sync centre tracking — re-sync triggered if GPS is more than 300 m from last sync centre. Database bumped to v11 to clear stale cache on upgrade.

**Status:** Partially resolved. Requires fresh install (uninstall + reinstall) for the database migration (v11) to run. If issue persists after fresh install, the ArcGIS dataset may not have building footprints at the user's exact GPS coordinates.

**Next Steps:**
1. Add a diagnostic screen showing the first 3 cached polygon centre coordinates to verify they match GPS.
2. Test the ArcGIS query directly from the device's network.
3. Consider switching from bounding box cache to a direct ArcGIS query on every map open.

---

### Issue B: Polygon Tap Popup Not Firing

**Symptom:** Tapping directly on a polygon does not open the building info popup.

**Root Cause:** `MarkerLayer` sits above `PolygonLayer` in the widget tree and consumes tap events. `FlutterMap` itself intercepts map pan/zoom gestures first.

**Fix Attempted (v3.2.17):** Migrated to flutter_map v7 native hit detection API (`hitNotifier`, `hitValue`). Added `IgnorePointer` to label markers.

**Status:** Partially resolved. Redesign using `mapController.mapEventStream.listen` (MapEventTap) is the recommended next step to avoid gesture conflicts entirely.

---

### Issue C: No Labels for Captured Buildings

**Symptom:** Buildings with existing customer records do not show a green name badge.

**Root Cause:** Building ID format mismatch between polygon cache and pickup records (e.g., `"9439 LASIKA06 006"` vs `"9439LASIKA06006"`).

**Status:** Open. Requires normalisation of building ID comparison in `_loadCustomerLabels()`.

---

## 4. Version History (v3.2.18 → v3.3.3)

| Version | Build | Key Change |
|---------|-------|-----------|
| v3.2.18 | — | Location-aware re-sync (300 m threshold), DB v11, `build.gradle` version fix |
| v3.3.0 | — | ArcGIS layer migrated to `Nigeria_Building_Footprints` |
| v3.3.1 | #78 | fix(arcgis): multi-unit socio-class majority vote + composite key |
| v3.3.2 | #79 | fix: update companies API URL from dead IP to upwork.kowope.xyz, reduce cache TTL to 1h |
| v3.3.3 | #80 | fix: add inline supervisor ID edit field for stuck unsynced submissions |

---

## 5. API Endpoints Wired

| Method | Path | Used in |
|--------|------|---------|
| `POST` | `/forms/submit` | Pickup form submission |
| `GET` | `/forms` | Form templates |
| `POST` | `/files` | Photo uploads |
| `GET` | `/api/mobile/companies` | Company list (updated URL) |
| `POST` | `/api/mobile/users/login` | Authentication |

---

## 6. Files Most Relevant to Outstanding Issues

| File | Issue |
|------|-------|
| `lib/widgets/enhanced_location_map.dart` | Issues A, B, C |
| `lib/services/arcgis_service.dart` | Issue A — sync radius and coordinate correctness |
| `lib/services/polygon_cache_service.dart` | Issue A — bounding box cache query |
| `lib/database/database_helper.dart` | Issue A — DB schema and migrations |
| `lib/screens/pickup_form_screen_v2.dart` | Supervisor ID edit (v3.3.3) |
| `android/app/build.gradle` | Version embedding (fixed) |

---

## 7. Ecosystem Reference

For the full project ecosystem overview, see:
`mottainai-platform-backend/docs/MOTTAINAI_ECOSYSTEM_OVERVIEW.md`
