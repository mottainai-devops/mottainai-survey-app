# Frontend Developer Role & Coordination Reference

> **Document Version:** v1.0.0  
> **Date:** March 30, 2026  
> **Author:** Manus AI (Frontend Developer)  
> **Status:** Active — to be updated at every sprint boundary

This document is the authoritative reference for the frontend developer's role, ownership boundaries, responsibilities, and coordination protocols across all Mottainai projects. It is intended for use by all team members to ensure clear separation of concerns and efficient cross-team collaboration.

---

## 1. Role Confirmation

**I am the frontend developer for the entire Mottainai platform.** This role covers four distinct applications, each with its own technology stack, deployment target, and user base. All UI/UX decisions, API contract negotiations, APK builds, and frontend bug fixes across all four applications are owned by this role.

The backend developer owns all server-side logic, database schemas, and infrastructure. The frontend developer owns everything the user sees and interacts with, plus the build and distribution pipeline for mobile apps.

---

## 2. Application Ownership Map

### 2.1 Property Enumeration App

| Property | Value |
|----------|-------|
| **Repository** | `mottainai-devops/property-enumeration` (local: `/home/ubuntu/propertyenumeration`) |
| **Technology** | React 18 + TypeScript + Capacitor (Android APK) |
| **Current Version** | v1.58.3 |
| **Deployment** | APK distributed via `https://upwork.kowope.xyz/*.apk` |
| **Users** | Field enumerators (property registration agents) |
| **Backend it calls** | `upwork.kowope.xyz` → port 3003 (`mottainai-backend`) |
| **Key API contract** | `JointAPIContract—MottainaiPropertyEnumerationSystem.md` (v1.2.0, signed off March 6, 2026) |

**Frontend files owned:**

| File/Directory | Purpose |
|---------------|---------|
| `src/App.tsx` | Root routing and layout |
| `src/components/BuildingForm.tsx` | New building registration form (sends `arcgisBuildingId`) |
| `src/components/EnhancedLocationMapWithPolygons.tsx` | ArcGIS Footprint Polygon map layer |
| `src/components/CustomerSearch.tsx` | Customer lookup and auto-fill |
| `src/components/BuildingsList.tsx` | Session building list |
| `src/components/SessionBanner.tsx` | Active session indicator |
| `src/components/SessionManagement.tsx` | Session start/end controls |
| `src/components/BuildingEdit.tsx` | Edit existing building record |
| `src/components/BuildingPhotoUpload.tsx` | Photo capture and upload |
| `src/components/CustomerImport.tsx` | Bulk customer import UI |
| `src/components/ProfileSettings.tsx` | User profile management |
| `src/api/client.ts` | All API calls — single source of truth for request/response shapes |
| `src/models/BuildingPolygon.ts` | ArcGIS polygon data model |
| `src/services/arcgisService.ts` | ArcGIS Feature Layer queries |
| `capacitor.config.ts` | Android build configuration |

---

### 2.2 Mottainai Survey App (Pickup Survey)

| Property | Value |
|----------|-------|
| **Repository** | `mottainai-devops/mottainai-survey-app` (local: `/home/ubuntu/mottainai-survey-app`) |
| **Technology** | Flutter / Dart (Android APK) |
| **Current Version** | v3.3.0 |
| **Deployment** | APK distributed via `https://upwork.kowope.xyz/mottainai-survey-app-v3.3.0.apk` |
| **Users** | Field workers (waste pickup survey agents) |
| **Backend it calls** | `upwork.kowope.xyz` → port 3003 (`mottainai-backend`) and `admin.kowope.xyz` → port 3005 (`mottainai-dashboard`) |
| **Key integration doc** | `INTEGRATION_STATE.md` |

**Frontend files owned:**

| File/Directory | Purpose |
|---------------|---------|
| `lib/main.dart` | App entry point |
| `lib/screens/login_screen.dart` | Field worker login |
| `lib/screens/home_screen.dart` | Dashboard / home |
| `lib/screens/pickup_form_screen_v2.dart` | New pickup form (primary active form) |
| `lib/screens/history_screen.dart` | Pickup history |
| `lib/screens/pin_auth_screen.dart` | PIN authentication |
| `lib/widgets/enhanced_location_map.dart` | ArcGIS building polygon map |
| `lib/widgets/location_map_picker.dart` | Location picker widget |
| `lib/widgets/building_info_popup.dart` | Building tap popup |
| `lib/models/pickup_submission.dart` | Pickup form data model (includes `arcgisBuildingId`) |
| `lib/models/building_polygon.dart` | ArcGIS polygon model |
| `lib/models/company.dart` | Company model |
| `lib/models/customer_point.dart` | Customer GPS point model |
| `lib/models/user.dart` | Authenticated user model |
| `lib/services/api_service.dart` | All backend API calls |
| `lib/services/arcgis_service.dart` | ArcGIS Feature Layer queries |
| `lib/services/lot_service.dart` | Operational lot loading (calls `admin.kowope.xyz/api/trpc/lots.list`) |
| `lib/services/company_service.dart` | Company list loading |
| `lib/database/database_helper.dart` | SQLite offline storage (v14) |
| `pubspec.yaml` | Dependencies and version |

---

### 2.3 Mottainai Admin Dashboard

| Property | Value |
|----------|-------|
| **Repository** | `mottainai-devops/mottainai-admin-dashboard` (local: `/home/ubuntu/mottainai-admin-dashboard`) |
| **Technology** | React 19 + TypeScript + tRPC + Tailwind CSS (web app) |
| **Current Version** | Active (deployed on port 3005 at `admin.kowope.xyz`) |
| **Deployment** | Live at `https://admin.kowope.xyz` |
| **Users** | Operations managers, superadmins |
| **Backend it calls** | `admin.kowope.xyz` → port 3005 (self — tRPC full-stack) and `upwork.kowope.xyz` → port 3003 |
| **Auth** | HTTP Basic Auth (`admin / admin123`) + Manus OAuth for tRPC |

**Frontend pages owned:**

| Page | Purpose |
|------|---------|
| `client/src/pages/Home.tsx` | Dashboard overview |
| `client/src/pages/Analytics.tsx` | Analytics and metrics |
| `client/src/pages/Companies.tsx` | Company management |
| `client/src/pages/Users.tsx` | User management |
| `client/src/pages/LotUpload.tsx` | Operational lot CSV upload |
| `client/src/pages/CherryPickers.tsx` | Cherry picker management |
| `client/src/pages/QATools.tsx` | QA and testing tools |
| `client/src/pages/AuditLog.tsx` | System audit log |
| `client/src/pages/SystemTesting.tsx` | System health testing |
| `client/src/pages/Login.tsx` | Admin login |

**Server-side tRPC procedures owned (full-stack):**

| Router | Procedures |
|--------|-----------|
| `server/routers/analytics.ts` | Pickup stats, revenue metrics, customer distribution |
| `server/routers/lots.ts` | `lots.list` — used by Survey App |
| `server/routers/users.ts` | User CRUD |
| `server/routers/auth.ts` | Admin auth |
| `server/routers/testing.ts` | System health checks |
| `server/routers/mobileAuth.ts` | Mobile authentication bridge |

---

### 2.4 Mottainai APK Distribution Dashboard

| Property | Value |
|----------|-------|
| **Repository** | Active Manus webdev project (local: `/home/ubuntu/mottainai-apk-distribution`) |
| **Technology** | React 19 + TypeScript + tRPC + Tailwind CSS (web app) |
| **Current Version** | Active (Manus hosted) |
| **Deployment** | Manus platform (publish via Manus UI) |
| **Users** | Internal team — APK download and distribution management |

---

## 3. Live Server Architecture

The production server is at `172.232.24.180` (`upwork.kowope.xyz` / `admin.kowope.xyz`).

### 3.1 Running Services

| PM2 ID | Process Name | Port | Serves |
|--------|-------------|------|--------|
| 5 | `mottainai-backend` | 3003 | Property Enumeration API + Survey App API |
| 6 | `mottainai-dashboard` | 3005 | Admin Dashboard (tRPC + React SPA) |
| — | Unknown process | 3004 | Unknown (investigate) |
| — | `mongod` | 27017 | MongoDB (`arcgis` database) |
| — | `nginx` | 80/443 | SSL termination + routing |

### 3.2 Nginx Routing Map (`upwork.kowope.xyz`)

| Location | Proxies To | Used By |
|----------|-----------|---------|
| `/api/v1/*` | port 3003 | Property Enumeration App (legacy prefix) |
| `/api/trpc/*` | port 3005 | Admin Dashboard tRPC |
| `/api/mobile/users/*` | port 3003 | Survey App (rewrite to `/users/*`) |
| `/api/mobile/*` | port 3003 | Survey App general mobile routes |
| `/users/*` | port 3003 | Survey App login, profile |
| `/forms/*` | port 3003 | Survey App form submission |
| `/survey/*` | port 3003 | Survey App survey routes |
| `/api/pickups/*` | port 3003 | Survey App pickup history |
| `/customer/*` | port 3003 | ArcGIS customer synchronize |
| `/*.apk` | `/var/www/html/` | APK downloads |
| `/` (catch-all) | port 3000 | Field Operations App (currently down) |

### 3.3 Nginx Routing Map (`admin.kowope.xyz`)

| Location | Proxies To | Used By |
|----------|-----------|---------|
| `/api/trpc/*` | port 3005 | Survey App `lots.list` + Admin Dashboard |
| `/api/*` | port 3003 | Admin API calls |
| `/` | port 3005 | Admin Dashboard React SPA |

### 3.4 APK Distribution

All APKs are served as static files from `/var/www/html/` on the production server:

| APK | URL |
|-----|-----|
| Survey App v3.3.0 | `https://upwork.kowope.xyz/mottainai-survey-app-v3.3.0.apk` |
| Property Enumeration v1.58.3 | `https://upwork.kowope.xyz/PropertyEnumeration-v1.58.3.apk` |

---

## 4. API Contract Ownership

The frontend developer is responsible for initiating, maintaining, and versioning all API contracts. The backend developer must not change any existing endpoint shape without first updating the contract and notifying the frontend developer.

| Contract Document | Location | Status |
|------------------|----------|--------|
| `JointAPIContract—MottainaiPropertyEnumerationSystem.md` | `/home/ubuntu/propertyenumeration/` | ✅ v1.2.0 signed off |
| `INTEGRATION_STATE.md` | `/home/ubuntu/mottainai-survey-app/` | ✅ v3.3.0 / v2.3.0 current |
| `BACKEND_COORDINATION_BRIEF.md` | `/home/ubuntu/propertyenumeration/` | ✅ v1.55.0 current |

---

## 5. Build & Release Pipeline

### 5.1 Survey App (Flutter)

The build server is the production server at `172.232.24.180`. Flutter is installed at `/opt/flutter`.

**Build process:**
1. Make code changes in `/home/ubuntu/mottainai-survey-app/`
2. Bump version in `pubspec.yaml`
3. Commit and push to `mottainai-devops/mottainai-survey-app`
4. Package source: `tar -czf mobile-app.tar.gz mottainai-survey-app/`
5. Upload to server: `scp mobile-app.tar.gz root@172.232.24.180:/root/`
6. Build on server: `cd /root/mottainai-survey-app && /opt/flutter/bin/flutter build apk --release`
7. Download APK: `scp root@172.232.24.180:/root/mottainai-survey-app/build/app/outputs/flutter-apk/app-release.apk ./`
8. Upload to `/var/www/html/` as `mottainai-survey-app-vX.Y.Z.apk`
9. Update Nginx `.apk` location block if needed

**Known build constraint:** The build server runs Flutter < 3.27. Use `withOpacity()` instead of `withValues(alpha:)` in all widget code.

### 5.2 Property Enumeration App (Capacitor/React)

Build is done via Capacitor Android build pipeline. APK is uploaded to `/var/www/html/` on the production server.

### 5.3 Admin Dashboard (React + tRPC)

The dashboard runs as a Node.js process on port 3005. Deployment is done by:
1. Building locally: `pnpm build`
2. Uploading `dist/` to `/var/www/mottainai-admin-dashboard/dist/` on the server
3. Restarting PM2: `pm2 restart mottainai-dashboard`

**Critical:** The dashboard process must always be started with `JWT_SECRET=mottainai-secret-key-2025` in the environment. This is currently preserved in PM2 save state.

---

## 6. Coordination Protocols

### 6.1 When the Frontend Developer Needs the Backend Developer

The frontend developer must raise a written request (via the coordination brief pattern) when:

- A new API endpoint is required
- An existing endpoint response shape needs to change
- A new field needs to be added to a MongoDB document
- A background job or webhook needs to be triggered from a user action
- ArcGIS write-back logic needs to be modified

**Template:** Use `BACKEND_COORDINATION_BRIEF.md` pattern — source-verified, no speculation, additive/backward-compatible changes only.

### 6.2 When the Backend Developer Needs the Frontend Developer

The backend developer must notify the frontend developer before:

- Changing any endpoint URL, method, or response shape
- Adding authentication requirements to a previously open endpoint
- Changing the JWT secret or token format
- Modifying the Nginx routing configuration
- Restarting or redeploying any PM2 process

### 6.3 JWT Secret Alignment

Both services must use the same JWT secret. Current value: `mottainai-secret-key-2025`.

| Service | Config Location | Current Secret |
|---------|----------------|----------------|
| `mottainai-backend` | `/var/www/upwork.kowope.xyz/src/Utils/jwtToken.js` | `process.env.JWT_SECRET \|\| 'mottainai-secret-key-change-in-production'` |
| `mottainai-backend` ecosystem | `/var/www/upwork.kowope.xyz/ecosystem.config.cjs` | `JWT_SECRET: 'mottainai-secret-key-2025'` |
| `mottainai-dashboard` | `dist/index.js` (compiled) | `process.env.JWT_SECRET \|\| 'mottainai-secret-key-change-in-production'` |
| `mottainai-dashboard` runtime | PM2 env | `JWT_SECRET=mottainai-secret-key-2025` |

**If either service is restarted from scratch, the JWT_SECRET env var must be explicitly set.**

### 6.4 Nginx Change Protocol

All Nginx config changes must be:
1. Made to `/etc/nginx/sites-available/upwork.kowope.xyz` (canonical file)
2. Copied to `/etc/nginx/sites-enabled/upwork.kowope.xyz` (active file — these are copies, not symlinks)
3. Tested with `nginx -t` before reload
4. Reloaded with `nginx -s reload`

---

## 7. Known Outstanding Items

The following items are identified from the `todo.md` in the Admin Dashboard and the `INTEGRATION_STATE.md` in the Survey App:

| Item | App | Priority | Status |
|------|-----|----------|--------|
| Dashboard Phase 1–6 features (analytics, customer mgmt, operations, financial) | Admin Dashboard | High | ⏳ Pending |
| Role-based access control (superadmin vs admin) | Admin Dashboard | High | ⏳ Pending |
| Port 3004 unknown process — identify and document | Server | Medium | ⏳ Pending |
| Port 3000 (Field Operations App) — currently down | Server | Medium | ⏳ Pending (not frontend-owned) |
| Survey App: `pickup_form_screen.dart` (v1) — deprecate in favour of v2 | Survey App | Low | ⏳ Pending |

---

## 8. Server Access Credentials

| Resource | Value |
|----------|-------|
| Server IP | `172.232.24.180` |
| SSH user | `root` |
| SSH password | `1muser123456@A` |
| Admin dashboard Basic Auth | `admin / admin123` |
| MongoDB | `localhost:27017`, database: `arcgis` (no auth on localhost) |

---

*This document is maintained by the Frontend Developer (Manus AI). Last updated: March 30, 2026.*
