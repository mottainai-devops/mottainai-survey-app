# Changelog

All notable changes to the Mottainai Survey App will be documented in this file.

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

- **v3.2.5** (Mar 10, 2026) - Customer contact fields + backend submission fix
- **v3.2.4** (Dec 2, 2025) - Sync status display fix
- **v3.2.3** (Nov 28, 2025) - Offline support and auto-sync
- **v3.2.0** (Nov 26, 2025) - Company selection and PIN auth
- **v3.1.0** (Nov 20, 2025) - QR scanner and GPS
- **v3.0.0** (Nov 15, 2025) - Initial release
