# Frontend Developer Response — Mottainai Platform
> **To:** Backend / DevOps Team
> **From:** Manus AI (Frontend Developer)
> **Date:** April 10, 2026
> **Re:** Your update dated April 10, 2026 — Issues A, B, C and Integration State

Thank you for the detailed update. I have conducted a full review of the current codebase against each item raised. Below is my response on each outstanding issue, followed by the updated integration state.

---

## 1. Receipt Confirmed

Your update has been received and reviewed in full. The API contract at v1.3.0, the service status table, and the LASIKA06 GIS dependency are all noted. The three production services (`mottainai-backend`, `mottainai-dashboard`, `franchisee-api`) being PM2-saved is also confirmed and appreciated.

---

## 2. Issue Status — Corrected Assessment

After a line-by-line inspection of the current `enhanced_location_map.dart`, `arcgis_service.dart`, and the full git log, I need to correct the status of Issues A and B in your update. The document appears to have been based on the codebase state as of March 30, 2026. Three releases have shipped since then (v3.3.1 on April 6, v3.3.2 on April 7, v3.3.3 on April 8), and the issues were resolved in earlier releases that pre-date your review.

---

### Issue A: Polygons Rendered Far from GPS Location

**Your assessment:** Open. Recommended a diagnostic screen and switching from bounding-box cache to direct ArcGIS queries.

**Actual status: ✅ Resolved in v3.2.18 (March 10, 2026)**

This was addressed in commit `c5b54ee` — *"fix: polygons appear far from GPS — re-sync when location moves >300m (v3.2.18)"*. The fix implemented:

- A Haversine distance helper `_distanceMetres()` to calculate GPS drift
- A 300m re-sync trigger stored in `SharedPreferences` (`last_sync_lat` / `last_sync_lon`) — if the user's GPS has moved more than 300m from the last sync centre, a fresh ArcGIS fetch is triggered automatically
- DB version bumped to v11 to force-clear stale polygon cache on upgrade

Regarding your recommendation to switch from bounding-box cache to direct ArcGIS queries: the current `_loadPolygonsNearLocation()` already uses a **direct ArcGIS query with a 0.5km radius** — there is no bounding-box cache dependency in the primary load path. The architecture you recommended is what is already in place.

The diagnostic screen is not needed at this time. If field reports of misplaced polygons resurface after the v3.3.3 layer migration, we can revisit.

---

### Issue B: Polygon Tap Popup Not Firing

**Your assessment:** "Partially resolved in v3.2.17." Recommended redesigning to use `mapController.mapEventStream.listen(MapEventTap)`.

**Actual status: ✅ Fully resolved in v3.2.17 (March 10, 2026)**

The v3.2.17 fix was complete, not partial. The current implementation uses:

- `MapOptions.onTap` callback which calls `_findPolygonAtPoint()` — a ray-casting point-in-polygon algorithm using `_isPointInPolygon()`
- Label markers use `GestureDetector` with `HitTestBehavior.deferToChild` — labels fire their own tap handler without blocking the map's `onTap`
- The label tap → start pickup directly for that unit; polygon tap → open full building confirmation sheet. This correctly implements the established UI/UX preference (label = non-confirming view action; polygon = primary confirming action)

The `MapEventTap` stream redesign is not required. The current ray-casting approach is correct, fully functional, and already in production. Redesigning a working tap handler introduces regression risk with no benefit.

---

### Issue C: No Labels for Captured Buildings

**Your assessment:** Open. Root cause is building ID format mismatch. Recommended a `replaceAll(' ', '')` normalisation fix.

**Actual status: ⚠️ Partially valid — applying as a defensive fix**

The current `_liveCustomers` map is populated by querying the **ArcGIS Customer Layer directly** via `fetchCustomersForBuildings()` — it does not compare against local pickup records. Both the polygon `building_id` and the customer `building_id` originate from ArcGIS, so they should be in the same format.

However, your concern is valid as a defensive measure: historical customer records written via old form submissions may have stored building IDs without spaces. The `replaceAll` normalisation is a two-line fix with zero risk and will handle any legacy inconsistency. I will apply this fix and release as **v3.3.4**.

---

## 3. Updated Action Summary

| Item | Status | Notes |
|------|--------|-------|
| Issue A: Polygon diagnostic + re-sync | ✅ Done (v3.2.18, Mar 10) | 300m Haversine re-sync already live |
| Issue B: Polygon tap redesign | ✅ Done (v3.2.17, Mar 10) | Ray-casting + deferToChild working correctly |
| Issue C: Building ID normalisation | 🔄 In progress → v3.3.4 | Applying as defensive fix |
| LASIKA06 buildings in ArcGIS layer | ⏳ Awaiting GIS Team | No action from frontend until published |
| Change Password screen | 📋 Backlog | Backend endpoint confirmed ready |
| Customer profile / edit / delete | 📋 Backlog | Backend endpoints confirmed ready |

---

## 4. Integration State Document

I will update `INTEGRATION_STATE.md` in the Survey App repository to reflect the corrected issue statuses and the v3.3.4 release once the Issue C fix is applied. The document's "Last Updated" date will be bumped to April 10, 2026.

---

## 5. One Item for Your Attention

The admin dashboard at `admin.kowope.xyz/pickup-records` still shows the subtitle **"View all pickup records synced from the mobile app"** and the card description **"All pickup records from mobile app submissions"**. These labels are factually incorrect — the vast majority of the 22,249 records were submitted via the web form, not the mobile app. A fix was committed to the `mottainai-admin-dashboard` repository (commit `f28a6d3`) updating these labels to reflect all three channels (web form, mobile app, Survey123) and adding a "Survey123" source badge. Please deploy this change at your next convenience.

---

*Frontend Developer — Manus AI*
*April 10, 2026*
*References: Survey App CHANGELOG.md | INTEGRATION_STATE.md v3.3.3 | FRONTEND_DEVELOPER_ROLE.md v1.0.0*
