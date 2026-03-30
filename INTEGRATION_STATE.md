> **Instructions for Agents**: This document is the single source of truth for the integration between the mobile app and the backend. Both agents **MUST** read this file at the start of each session and update it at the end of each session to reflect any changes that affect the other agent.

# Integration State & API Contract

**Last Updated**: March 30, 2026

---

## 1. System Status

| Component | Version | Last Updated | Key Details |
| :--- | :--- | :--- | :--- |
| 📱 **Mobile App** | `v3.3.0` | Mar 30, 2026 | `arcgisBuildingId` field added; SQLite DB v14; Flutter compat fixes |
| ☁️ **Backend (old)** | `v2.3.0` | Mar 30, 2026 | Login/submit API URL: `https://upwork.kowope.xyz`; geographic fields + ArcGIS write-back added |
| 🖥️ **Admin Dashboard Backend** | `v1.x` | Mar 30, 2026 | Lots API URL: `https://admin.kowope.xyz` — Nginx `/api/trpc` block fixed; JWT secret aligned |
| 🗃️ **Database** | `v14` (SQLite) | Mar 30, 2026 | `arcgisBuildingId` column added to `pickups` table |

---

## 2. API Contract

This section defines the API contract between the mobile app and the backend. The mobile app relies on these endpoints and data structures.

### `POST /forms/submit`

This endpoint is used to submit a new pickup record from the mobile app.

#### Mobile App Payload (What the app sends)

The mobile app sends a JSON object with the following structure and data types:

```json
{
  "customerName": "string",
  "customerPhone": "string",
  "customerEmail": "string",
  "customerAddress": "string",
  "customerType": "string",
  "binType": "string",
  "wheelieBinType": "string?",
  "binQuantity": "int",
  "buildingId": "string",
  "pickUpDate": "string",
  "firstPhoto": "file (multipart)",
  "secondPhoto": "file (multipart)",
  "incidentReport": "string?",
  "userId": "string",
  "latitude": "double",
  "longitude": "double",
  "createdAt": "string",
  "companyId": "string?",
  "companyName": "string?",
  "arcgisBuildingId": "string?",
  "lotCode": "string?",
  "lgaName": "string?",
  "lgaCode": "string?",
  "stateCode": "string?",
  "country": "string?",
  "wardCode": "string?",
  "wardName": "string?"
}
```

**Key Field Details**:
- `pickUpDate` is sent in the format: `'MMM dd, yyyy'` (e.g., "Mar 10, 2026").
- `createdAt` is sent in ISO 8601 format.
- `socioClass` is required for residential customers (values: "low", "medium", "high").
- `wheelieBinType`, `incidentReport`, `companyId`, `companyName`, and `socioClass` (for commercial) are optional and may be `null`.
- Photos are sent as multipart/form-data files, not as paths.
- Backend calculates pricing automatically - mobile app does NOT send price/amount.
- `customerName`, `customerPhone`, `customerAddress` are required fields in the form.
- `customerEmail` is optional.

#### Backend Response (What the app expects)

- **On Success**: `200 OK` or `201 Created` with `{"status": "success", "message": "Form submitted successfully", "form": {...}}`.
- **On Failure**: Non-2xx status code with `{"status": "error", "message": "..."}` or `{"error": "..."}`.

---

## 3. Known Integration Issues & Pending Changes

### Current Issues

#### ✅ RESOLVED (Mar 30, 2026) — `lots.list` now returns correct lots for all users

**Symptom:** All regular (non-admin, non-cherry-picker) users see "No operational lots available for your account" on the New Pickup screen. Admin and cherry-picker accounts are unaffected.

**Root Cause:** `companyId` type mismatch in `server/routers/lots.ts` on `admin.kowope.xyz`.

- The filter on line 81 compares `lot.companyId` (built from `company._id.toString()` — a MongoDB ObjectId hex string, e.g. `"69185eebf21dfa8ce0f9a7aa"`) against `user.companyId` (stored by the old `upwork.kowope.xyz` login backend as a legacy string, e.g. `"URBAN-SPIRIT"`).
- These two values are **different formats** and will never match, so all regular users get zero lots.
- The `Company` model has two fields: `_id` (ObjectId) and `companyId` (legacy string). The filter only checks `_id`, not `companyId`.

**Required Backend Fix** (file: `server/routers/lots.ts` on `admin.kowope.xyz`):

**Step 1** — Add `companyId` to the DB select (~line 52):
```ts
// BEFORE
const companies = await Company.find({ active: true }).select('companyName operationalLots');
// AFTER
const companies = await Company.find({ active: true }).select('companyId companyName operationalLots');
```

**Step 2** — Expose the legacy `companyId` in each lot object (~line 62):
```ts
// ADD this line inside the flatMap lot object:
companyLegacyId: company.companyId,   // Legacy string ID (e.g. "URBAN-SPIRIT")
```

**Step 3** — Fix the filter to match against either format (~line 81):
```ts
// BEFORE
filteredLots = allLots.filter(lot => lot.companyId === user.companyId);
// AFTER
filteredLots = allLots.filter(lot =>
  lot.companyId === user.companyId ||
  lot.companyLegacyId === user.companyId
);
```

**Resolution applied (Mar 30, 2026):** The root cause was not the `companyId` type mismatch but a combination of: (1) `admin.kowope.xyz` Nginx had no `/api/trpc` location block — requests returned `{"error":"Route not found"}`; (2) `mottainai-dashboard` process was not picking up `JWT_SECRET` from `ecosystem.config.js`, so tokens from `upwork.kowope.xyz` backend were rejected; (3) `jwtToken.js` on the backend used a hardcoded secret `'sjdhasjkdhaskj'` instead of `process.env.JWT_SECRET`. All three issues fixed. No mobile app rebuild required.

**Verification:**
```bash
curl 'https://admin.kowope.xyz/api/trpc/lots.list?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22userId%22%3A%226622b0d1f9f81b0481c7e99f%22%7D%7D%7D'
# Returns: LOT-6: G R A (Ikeja) with userRole: "user"
```

---

**Previously resolved issues (as of v3.2.5, Mar 10, 2026):**

1. ✅ **Customer contact fields** - `customerName`, `customerPhone`, `customerEmail`, `customerAddress` now collected in form and sent to backend
2. ✅ **Backend submission failure** - Root cause was `customerName` being sent as `"default_form_id"` placeholder. Fixed in v3.2.5.
3. ✅ **Zoho Sync** - Working with auto-refresh
4. ✅ **S3 Photo Storage** - Configured (AWS eu-west-1, bucket: mottainai-photos)
5. ✅ **Price Calculation** - Server-side with all 9 pricing tiers
6. ✅ **Pickup Details API** - `GET /api/pickups/:id` endpoint available

### Pending Changes

- ✅ **RESOLVED (2026-03-30)**: `lots.list` now works for all users on `admin.kowope.xyz`. See resolution details above.
- ✅ **RESOLVED (2026-03-30)**: ArcGIS Customer Layer write-back implemented on `upwork.kowope.xyz`. `POST /customer/synchronize` writes `lga_name`, `lga_code`, `state_code`, `ward_code`, `ward_name`, `Lat`, `Long` to ArcGIS Customer Layer. Geographic fields added to `customerData` and `formSubmission` MongoDB models.

---

## 4. Change Log

| Date | System | Agent | Change Description |
| :--- | :--- | :--- | :--- |
| Mar 30, 2026 | Mobile | Manus | **v3.3.0 Release**: Added `arcgisBuildingId` field to `PickupSubmission`; SQLite DB v14 migration; Flutter `withOpacity()` compat fix; APK at `https://upwork.kowope.xyz/mottainai-survey-app-v3.3.0.apk` |
| Mar 30, 2026 | Old Web Backend | Manus | **v2.3.0 Release**: `POST /customer/synchronize` + `POST /customer/triggerGeoBackfill` endpoints live; `customerData` + `formSubmission` models updated with 7/8 geographic fields; `jwtToken.js` secret aligned with dashboard; Nginx routing fixed for `/users`, `/forms`, `/customer`, `/api/trpc` on both `upwork.kowope.xyz` and `admin.kowope.xyz` |
| Mar 30, 2026 | Admin Dashboard Backend | Manus | **Nginx fix**: Added `/api/trpc → port 3005` location block to `admin.kowope.xyz`; restarted `mottainai-dashboard` with correct `JWT_SECRET=mottainai-secret-key-2025` |
| Mar 26, 2026 | Mobile | Manus | **v3.2.46 Release**: Architecture compliance — CustomerPoint model gets `flatNo` field; `getNextUnitCode()` derives sequential R1/R2/C1/C2; `addCustomerToLayer()` uses composite key `building_id + flat_no`; label chips show unit code; label tap starts pickup directly |
| Mar 26, 2026 | Old Web Backend | Manus (instruction) | **FEATURE REQUEST**: ArcGIS Customer Layer write-back needed on `upwork.kowope.xyz` form submission. Full code in `backend-instructions-v2.pdf`. |
| Mar 26, 2026 | Admin Backend | Manus (diagnosis) | **BUG IDENTIFIED**: `lots.list` returns 0 lots for regular users due to `companyId` type mismatch. Backend patch required on `admin.kowope.xyz`. Full instructions in `backend-instructions-v2.pdf`. No mobile app change needed. |
| Mar 10, 2026 | Mobile | Manus | **v3.2.5 Release**: Added customer contact fields (name, phone, email, address) to pickup form; fixed backend submission failure caused by `customerName` being sent as `"default_form_id"` placeholder; bumped SQLite DB to v8 with migration for new columns |
| Nov 26, 2025 | Mobile | Manus | **v3.2.4 Release**: Fixed sync status display bug in history screen |
| Nov 26, 2025 | Mobile | Manus | **v3.2.3 Release**: CRITICAL FIX - Added socioClass column to database, fixed blocking bug |
| Nov 26, 2025 | Mobile | Manus | **v3.2.2 Release**: Improved error handling for backend HTML errors |
| Nov 26, 2025 | Mobile | Manus | **v3.2.1 Release**: Fixed tap detection (deferToChild behavior) |
| Nov 26, 2025 | Mobile | Manus | **v3.2.0 Release**: Clear label/polygon distinction, socio-class auto-fill (had broken tap detection) |
| Nov 25, 2025 | Backend | Backend Agent | **v2.2.0 Release**: Zoho integration, S3 photo storage, server-side pricing, pickup details API |
| Nov 25, 2025 | Mobile | Manus | **v3.1.1 Release**: Fixed companyId submission (uses user's companyId), enables Company filter in admin dashboard |
| Nov 25, 2025 | Mobile | Manus | **v3.1.0 Release**: Updated API URL to https://upwork.kowope.xyz, added socioClass field for residential customers, photo upload via multipart/form-data, removed loading blocker |
| Nov 24, 2025 | Mobile | Manus | **v3.0.0 Release**: Fixed zoom level, tap behavior, placeholder text, and read-only date field |

---

## 5. Backend Developer Summation — March 30, 2026

> **Source document:** `BackendDeveloperCoordinationNotification.md` (uploaded by backend developer, March 30, 2026)

The backend developer confirmed the following server-side changes were made during their session. These are recorded here so the frontend team has a complete picture of what changed on the live server.

### 5.1 Admin Dashboard Server-Side Changes (port 3005, `/var/www/mottainai-dashboard/`)

| File | Change | Impact on Frontend |
|------|--------|--------------------|
| `server/models/Customer.ts` | 7 geographic fields added (`arcgisBuildingId`, `lgaName`, `lgaCode`, `stateCode`, `country`, `wardCode`, `wardName`) | Update local `Customer` interface in `Customers.tsx` |
| `server/models/FormSubmission.ts` | 8 geographic fields added (same 7 + `lotCode`) | Update local pickup/submission interface in `PickupRecords.tsx` |
| `server/routers/pickups.ts` | Pickup transformer now returns all 7 geographic fields; `null` for historical records — **no breaking change** | Add `lgaName`, `wardName`, `lotCode` columns to `PickupRecords.tsx` table |
| `server/routers/propertyEnumeration.ts` | `triggerGeoBackfill` mutation: 3 broken template literals restored (bash heredoc substitution bug from prior deploy) | Wire to a button in `QATools.tsx` or `SystemTesting.tsx` |
| `client/src/pages/Customers.tsx` | Geographic Information card added to customer detail dialog | Verify card renders correctly after next rebuild |

### 5.2 PM2 Process Status (Confirmed March 30, 2026)

| Process | Port | PID | JWT_SECRET | Status |
|---------|------|-----|-----------|--------|
| `mottainai-dashboard` | 3005 | 3171619 | `mottainai-secret-key-2025` | ✅ Online |
| `mottainai-backend` | 3003 | 3165596 | `mottainai-secret-key-2025` | ✅ Online |

### 5.3 Files Confirmed NOT Modified by Backend Team

The backend developer explicitly confirmed the following were not touched — these remain under frontend ownership and their state is as left by the frontend team:

- All Nginx configuration files (`/etc/nginx/sites-enabled/upwork.kowope.xyz`, `admin.kowope.xyz`)
- `mottainai-backend` source code at `/var/www/upwork.kowope.xyz/`
- All API endpoint URLs, methods, and response shapes
- MongoDB schema (no new collections or indexes)
- ArcGIS Footprint Polygon Layer (read-only during session)
- Survey App APK (`mottainai-survey-app-v3.3.0.apk`)
- Property Enumeration App APK (`PropertyEnumeration-v1.58.3.apk`)

### 5.4 Frontend Actions Required (from Backend Summation)

| Priority | App | Action | Status |
|----------|-----|--------|--------|
| ⚠️ High | Admin Dashboard | Update local `Customer` TypeScript interface with 7 new geographic fields | ✅ Complete (already present in live `Customers.tsx`) |
| ⚠️ High | Admin Dashboard | Update local `FormSubmission`/pickup TypeScript interface with 8 new fields | ✅ Complete (all 8 fields returned by `pickups.ts` transformer) |
| ⚠️ High | Admin Dashboard | Add geographic columns (`lgaName`, `wardName`, `lotCode`) to `PickupRecords.tsx` table | ✅ Complete (LGA + Ward columns added; Lot column updated to use `lotCode` field) |
| ⚠️ High | Admin Dashboard | Verify `Customers.tsx` Geographic Information card renders correctly after rebuild | ✅ Complete (card verified in live code; dashboard rebuilt and redeployed) |
| Medium | Admin Dashboard | Wire `triggerGeoBackfill` mutation to a button in `QATools.tsx` or `SystemTesting.tsx` | ✅ Complete (Geographic Backfill card added to `QATools.tsx` with batch size control and result display) |
| Low | Property Enumeration App | No changes required — `arcgisService.ts` benefits automatically from expanded Customer Layer | ✅ No action needed |
| Low | Survey App | No changes required — v3.3.0 is current and all fields are being sent | ✅ No action needed |

### 5.5 Change Log Additions (from Backend Summation)

| Date | System | Agent | Change Description |
|------|--------|-------|-------------------|
| Mar 30, 2026 | Admin Dashboard Backend | Backend Developer | **Dashboard model update**: `Customer.ts` + `FormSubmission.ts` geographic fields added; `pickups.ts` transformer updated; `triggerGeoBackfill` template literals fixed; `Customers.tsx` geographic card added |
| Mar 30, 2026 | Admin Dashboard Backend | Backend Developer | **PM2 restart**: Both `mottainai-dashboard` (port 3005) and `mottainai-backend` (port 3003) confirmed online with `JWT_SECRET=mottainai-secret-key-2025` |
| Mar 30, 2026 | Admin Dashboard Frontend | Manus | **Frontend updates complete**: Added LGA + Ward columns to `PickupRecords.tsx` table; updated Lot column to use dedicated `lotCode` field; added Geographic Backfill card to `QATools.tsx` with `trpc.propertyEnumeration.triggerGeoBackfill` mutation; registered `pickupsRouter`, `customersRouter`, `propertyEnumerationRouter` in `server/routers.ts`; added `getMongoDb()` helper to `mongodb.ts`; synced 8 previously untracked live pages + 5 server models + 11 server routers to GitHub; built and deployed to `admin.kowope.xyz` (PM2 process 6 restarted) |
