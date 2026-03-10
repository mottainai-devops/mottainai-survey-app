> **Instructions for Agents**: This document is the single source of truth for the integration between the mobile app and the backend. Both agents **MUST** read this file at the start of each session and update it at the end of each session to reflect any changes that affect the other agent.

# Integration State & API Contract

**Last Updated**: March 10, 2026

---

## 1. System Status

| Component | Version | Last Updated | Key Details |
| :--- | :--- | :--- | :--- |
| 📱 **Mobile App** | `v3.2.5` | Mar 10, 2026 | APK: `mottainai-survey-app-v3.2.5-fat.apk` |
| ☁️ **Backend** | `v2.2.0` | Nov 25, 2025 | API URL: `https://upwork.kowope.xyz` |
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

**✅ All known issues resolved as of v3.2.5 (Mar 10, 2026)**

1. ✅ **Customer contact fields** - `customerName`, `customerPhone`, `customerEmail`, `customerAddress` now collected in form and sent to backend
2. ✅ **Backend submission failure** - Root cause was `customerName` being sent as `"default_form_id"` placeholder. Fixed in v3.2.5.
3. ✅ **Zoho Sync** - Working with auto-refresh
4. ✅ **S3 Photo Storage** - Configured (AWS eu-west-1, bucket: mottainai-photos)
5. ✅ **Price Calculation** - Server-side with all 9 pricing tiers
6. ✅ **Pickup Details API** - `GET /api/pickups/:id` endpoint available

### Pending Changes

None at this time.

---

## 4. Change Log

| Date | System | Agent | Change Description |
| :--- | :--- | :--- | :--- |
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
