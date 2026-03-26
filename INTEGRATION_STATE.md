> **Instructions for Agents**: This document is the single source of truth for the integration between the mobile app and the backend. Both agents **MUST** read this file at the start of each session and update it at the end of each session to reflect any changes that affect the other agent.

# Integration State & API Contract

**Last Updated**: March 26, 2026

---

## 1. System Status

| Component | Version | Last Updated | Key Details |
| :--- | :--- | :--- | :--- |
| 📱 **Mobile App** | `v3.2.46` | Mar 26, 2026 | Architecture compliance: unit code (R1/C2) labels, composite key upsert, direct pickup from label tap |
| ☁️ **Backend (old)** | `v2.2.0` | Nov 25, 2025 | Login/submit API URL: `https://upwork.kowope.xyz` |
| 🖥️ **Admin Dashboard Backend** | `v1.x` | Mar 26, 2026 | Lots API URL: `https://admin.kowope.xyz` — **PATCH REQUIRED (see Section 3)** |
| 🗃️ **Database** | `v8` (SQLite) | Mar 10, 2026 | `customerName`, `customerPhone`, `customerEmail`, `customerAddress` columns added to `pickups` |

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
  "companyName": "string?"
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

#### 🔴 OPEN — `lots.list` returns 0 lots for all regular users (Mar 26, 2026)

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

**After fix:** Rebuild backend bundle and restart PM2 (`pm2 restart mottainai-dashboard`). No mobile app rebuild required.

**Verification curl** (should return non-empty lots after fix):
```bash
curl 'https://admin.kowope.xyz/api/trpc/lots.list?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22userId%22%3A%226622b0d1f9f81b0481c7e99f%22%7D%7D%7D'
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

- ⏳ **Backend team**: Apply `lots.list` companyId fix to `admin.kowope.xyz` (see open issue above). Full instructions in `backend-instructions-v2.pdf`.
- ⏳ **Backend team (old backend)**: Add ArcGIS Customer Layer write-back to `upwork.kowope.xyz` form submission handler so web-survey-captured buildings appear on the map and participate in the R1/C2 unit code system. Full instructions in `backend-instructions-v2.pdf` (Section: ArcGIS Customer Layer Write-Back).

---

## 4. Change Log

| Date | System | Agent | Change Description |
| :--- | :--- | :--- | :--- |
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
