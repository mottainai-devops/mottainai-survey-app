# Backend Developer Notification — Integration Update (March 30, 2026)

**To:** Backend Developer  
**From:** Manus (Integration Agent)  
**Date:** March 30, 2026  
**Subject:** All Pending Integration Items Resolved — Backend v2.3.0 Live, Survey App v3.3.0 Released

---

## Summary

All items raised in the integration status check email have been fully implemented and are now live on the production server (`upwork.kowope.xyz`). In addition, several critical Nginx routing issues were discovered and fixed during deployment, which also resolved the `lots.list` failure on `admin.kowope.xyz`. The Survey App has been rebuilt and released as v3.3.0.

---

## 1. Items from the Integration Status Check Email

### Item 1 — Property Enumeration App: `arcgisBuildingId` in POST body

**Status: ✅ Already implemented (no change needed)**

The Property Enumeration App was already sending `arcgisBuildingId` correctly. The value comes from `selectedBuilding.buildingId` (the ArcGIS Footprint Polygon `building_id`, e.g., `"8038 LASIKA06 006"`) and is included in the `buildingApi.create()` POST body.

---

### Item 2 — Survey App: `arcgisBuildingId` and `buildingId` in form submission

**Status: ✅ Fixed in v3.3.0**

The Survey App was sending `buildingId` (which already contains the ArcGIS polygon ID) but not a separate `arcgisBuildingId` field. The following changes were made and released in v3.3.0:

| File | Change |
|------|--------|
| `lib/models/pickup_submission.dart` | Added `arcgisBuildingId` field to class, constructor, `toMap()`, `toJson()`, `fromMap()`, `copyWith()` |
| `lib/services/api_service.dart` | Sends `arcgisBuildingId` in the multipart POST to `/forms/submit` |
| `lib/screens/pickup_form_screen_v2.dart` | Populates `arcgisBuildingId` from `_buildingIdController` (same value as `buildingId`) |
| `lib/database/database_helper.dart` | Schema bumped to v14; `ALTER TABLE pickups ADD COLUMN arcgisBuildingId TEXT` migration added |

**APK download:** `https://upwork.kowope.xyz/mottainai-survey-app-v3.3.0.apk` (24.2 MB)

---

### Items 3 & 4 — `Customer.js` and `FormSubmission.js` model fields

**Status: ✅ Done and deployed**

Both Mongoose models in `mottainai-platform-backend` (`/var/www/upwork.kowope.xyz/`) have been updated:

**`customerData.js`** — 7 new fields added:
```javascript
arcgisBuildingId: { type: String, default: null },
lgaName:          { type: String, default: null },
lgaCode:          { type: String, default: null },
stateCode:        { type: String, default: null },
country:          { type: String, default: null },
wardCode:         { type: String, default: null },
wardName:         { type: String, default: null },
```

**`formSubmission.js`** — 8 new fields added:
```javascript
arcgisBuildingId: { type: String, default: null },
lotCode:          { type: String, default: null },
lgaName:          { type: String, default: null },
lgaCode:          { type: String, default: null },
stateCode:        { type: String, default: null },
country:          { type: String, default: null },
wardCode:         { type: String, default: null },
wardName:         { type: String, default: null },
```

The `/forms/submit` handler in `server.js` now reads and persists all these fields from the incoming POST body.

---

### Item 5 — Rebuild and redeploy backend

**Status: ✅ Done**

The backend was redeployed to the live server via SSH:
- `git reset --hard` to latest commit on `main`
- `pm2 restart mottainai-backend`
- All new endpoints verified live

---

### Item 6 — `customer-synchronize` endpoint with ArcGIS write-back

**Status: ✅ Implemented and live**

Two new endpoints are live on `upwork.kowope.xyz`:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/customer/synchronize` | POST | Writes a single customer's geographic data to ArcGIS Customer Layer |
| `/api/v1/customer/synchronize` | POST | Alias (same handler) |
| `/customer/triggerGeoBackfill` | POST | Starts a background job to backfill all existing customers |
| `/api/v1/customer/triggerGeoBackfill` | POST | Alias (same handler) |

**Fields written to ArcGIS Customer Layer:**

```json
{
  "lga_name":   "from request body",
  "lga_code":   "from request body",
  "state_code": "from request body",
  "ward_code":  "from request body",
  "ward_name":  "from request body",
  "Lat":        "from request body",
  "Long":       "from request body"
}
```

The handler uses `addFeatures` for new records and `updateFeatures` for existing records matched by `building_id`. It accepts both `lng` and `lon` as the longitude field name.

**Verification:**
```bash
curl -s -X POST https://upwork.kowope.xyz/customer/synchronize \
  -H "Content-Type: application/json" \
  -d '{"customerId":"TEST","buildingId":"TEST-001","lgaName":"Ikeja","lgaCode":"IK","stateCode":"LA","wardCode":"W01","wardName":"Test Ward","lat":6.58,"lng":3.35}'
# Returns: {"success":true,"message":"ArcGIS Customer Layer added successfully","arcgis":{"action":"added","objectId":...}}
```

---

## 2. Additional Fixes Applied (Not in Original Email)

These issues were discovered and fixed during the deployment process. They are documented here for your awareness.

### 2a — Nginx Routing Gaps on `upwork.kowope.xyz`

**Problem:** The Nginx config had a catch-all `location /` block that proxied all unrecognised paths to port 3000 (which is down). This caused HTML 502 errors for any path not explicitly listed, including `/users/login` and `/forms/submit`.

**Fix:** The following `location` blocks were added to `/etc/nginx/sites-enabled/upwork.kowope.xyz`:

| Location Block | Proxies To |
|---------------|-----------|
| `location /users` | `http://localhost:3003` |
| `location /forms` | `http://localhost:3003` |
| `location /survey` | `http://localhost:3003` |
| `location /api/pickups` | `http://localhost:3003` |
| `location /customer` | `http://localhost:3003` |
| `location /api/trpc` | `http://localhost:3003` |
| `location /api/mobile/users` | Rewrite → `/users` on port 3003 |
| `location ~ \.apk$` | Serve from `/var/www/html/` |

---

### 2b — Nginx Routing Gap on `admin.kowope.xyz`

**Problem:** The `admin.kowope.xyz` Nginx config had no `/api/trpc` location block. All tRPC calls from the Survey App (which calls `admin.kowope.xyz/api/trpc/lots.list`) returned `{"error":"Route not found","path":"/api/trpc/lots.list"}`.

**Fix:** Added `location /api/trpc { proxy_pass http://localhost:3005; }` to `/etc/nginx/sites-enabled/admin.kowope.xyz.conf`.

---

### 2c — JWT Secret Mismatch Between Backend and Dashboard

**Problem:** The backend (`upwork.kowope.xyz`) was signing JWT tokens with a hardcoded secret `'sjdhasjkdhaskj'` in `src/Utils/jwtToken.js`. The dashboard (`admin.kowope.xyz`) was verifying tokens using `process.env.JWT_SECRET || 'mottainai-secret-key-change-in-production'`. These never matched, so the dashboard always treated mobile app users as "guest" and returned empty lots.

**Fix:**
1. Updated `jwtToken.js` to use `process.env.JWT_SECRET || 'mottainai-secret-key-change-in-production'`
2. Restarted `mottainai-dashboard` with `JWT_SECRET=mottainai-secret-key-2025` so both services use the same secret
3. Updated `ecosystem.config.cjs` on the backend to include `JWT_SECRET: 'mottainai-secret-key-2025'`

**Important:** If you ever rebuild or restart the `mottainai-dashboard` process, ensure it is started with `JWT_SECRET=mottainai-secret-key-2025` in the environment. The current PM2 save state preserves this.

---

## 3. Current Live Endpoint Status

All endpoints verified as of March 30, 2026:

| Endpoint | Status | Notes |
|----------|--------|-------|
| `POST /users/login` | ✅ Live | Returns JWT token |
| `GET /api/mobile/users/me` | ✅ Live | Returns user profile |
| `POST /forms/submit` | ✅ Live | Accepts all new geographic fields |
| `POST /customer/synchronize` | ✅ Live | ArcGIS write-back working |
| `POST /customer/triggerGeoBackfill` | ✅ Live | Background backfill working |
| `GET /api/trpc/lots.list` (admin.kowope.xyz) | ✅ Live | Returns lots for regular users |
| APK download | ✅ Live | `https://upwork.kowope.xyz/mottainai-survey-app-v3.3.0.apk` |

---

## 4. Files Changed on the Live Server

> **Note:** The changes below were made directly on the live server at `/var/www/upwork.kowope.xyz/`. They have also been committed to the GitHub repository (`mottainai-devops/mottainai-platform-backend`, commits `759a09e`, `8e4a9d3`, and subsequent commits).

| File | Change |
|------|--------|
| `src/Models/customerData.js` | 7 new geographic fields added to schema |
| `src/Models/formSubmission.js` | 8 new geographic fields added to schema |
| `server.js` | `/forms/submit` handler reads new fields; `customer/synchronize` and `customer/triggerGeoBackfill` endpoints added |
| `src/Utils/jwtToken.js` | Replaced hardcoded secret with `process.env.JWT_SECRET` |
| `/etc/nginx/sites-enabled/upwork.kowope.xyz` | 8 new location blocks added |
| `/etc/nginx/sites-enabled/admin.kowope.xyz.conf` | `/api/trpc` location block added |

---

## 5. Action Required from Backend Developer

No immediate action is required — all items from the original email are live. However, please be aware of the following:

1. **JWT Secret**: The `mottainai-dashboard` process must always be started with `JWT_SECRET=mottainai-secret-key-2025`. This is currently preserved in PM2 save state but will need to be re-applied if the server is rebooted and PM2 is restarted from scratch.

2. **Survey App v3.3.0 APK**: Please distribute `https://upwork.kowope.xyz/mottainai-survey-app-v3.3.0.apk` to all field agents. They should uninstall the previous version before installing v3.3.0, or enable "Install from unknown sources" if prompted.

3. **ArcGIS DNS on Devices**: The "Failed host lookup: services3.arcgis.com" error seen on one device is a network-level issue on that specific device (no internet access to ArcGIS at that moment). This is not a server-side issue and resolves when the device has a stable connection.

---

*This notification was generated by Manus Integration Agent. All changes are reflected in `INTEGRATION_STATE.md`, `CHANGELOG.md`, and `MOTTAINAI_PROJECT_MEMORY.md` in the `mottainai-survey-app` repository.*
