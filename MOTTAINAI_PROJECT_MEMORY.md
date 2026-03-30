# Mottainai Project - Complete Memory & Workflow Documentation

**Project Owner**: mottainaisurvey  
**Last Updated**: March 30, 2026  
**Status**: Production Active

---

## 🎯 Project Overview

**Mottainai** is a waste management system with two main components:

1. **Admin Dashboard Backend** - Node.js API with role-based access control
2. **Mobile Survey App** - Flutter app for field workers to submit pickup data

**Production URL**: https://admin.kowope.xyz  
**Production Server**: 172.232.24.180 (root access)  
**Server Password (root)**: `Shams117@@@@`  
**Server Password (alt)**: `1muser123456@A`  
**Backend App URL**: https://upwork.kowope.xyz (port 3003, PM2: `mottainai-backend`)  
**Admin Dashboard URL**: https://admin.kowope.xyz (port 3005, PM2: `mottainai-dashboard`)  
**APK Distribution**: https://upwork.kowope.xyz/{filename}.apk (served from `/var/www/html/`)

---

## 📁 Project Structure & Locations

### Local Development (Manus Sandbox)
```
/home/ubuntu/mottainai-admin-dashboard/     # Backend API
/home/ubuntu/mottainai_survey_app/          # Flutter mobile app
```

### Production Server (172.232.24.180)
```
/root/mottainai-dashboard/                  # Backend (running via PM2)
/root/build-temp/                           # Temporary build directory for APK
```

### GitHub Repositories
```
https://github.com/mottainaisurvey/mottainai-admin-dashboard
https://github.com/mottainaisurvey/mottainai-survey-app
```

---

## 🔧 Technology Stack

### Backend (Admin Dashboard)
- **Runtime**: Node.js 22.13.0
- **Package Manager**: pnpm
- **Framework**: Express 4 + tRPC 11
- **Database**: MongoDB (hosted, connection via MONGODB_URI)
- **Process Manager**: PM2 (on production)
- **Authentication**: JWT tokens + Manus OAuth

### Mobile App
- **Framework**: Flutter 3.5.4+
- **Language**: Dart
- **Local Storage**: SQLite + SharedPreferences
- **Maps**: ArcGIS Feature Services
- **Build Tool**: Android SDK + Gradle

---

## 🗄️ Database Architecture

### MongoDB Collections

**users** - User accounts with role-based access
```javascript
{
  _id: ObjectId,
  email: String,
  password: String (bcrypt hashed),
  name: String,
  role: "admin" | "cherry_picker" | "user",
  companyId: ObjectId,  // Reference to companies
  createdAt: Date,
  updatedAt: Date
}
```

**companies** - Waste management companies
```javascript
{
  _id: ObjectId,
  company_id: String,
  company_name: String,
  is_active: Boolean,
  created_at: Date,
  updated_at: Date
}
```

**lots** - Operational lots (pickup locations)
```javascript
{
  _id: ObjectId,
  lotCode: String,        // e.g., "LOT-6"
  lotName: String,        // e.g., "G R A (Ikeja)"
  companyId: String,
  companyName: String,
  paytWebhook: String,    // Payment webhook URL
  monthlyWebhook: String, // Monthly billing webhook URL
  isActive: Boolean
}
```

### Database Connection
- **URI**: Stored in `MONGODB_URI` environment variable
- **Access**: Via MongoDB Compass or mongo shell
- **Connection String Format**: `mongodb://username:password@host:port/database`

---

## 🔐 Authentication & Authorization

### User Roles & Access Control

**Role: admin**
- Full access to all lots across all companies
- Can manage users and companies
- Web dashboard access

**Role: cherry_picker**
- Special field worker with cross-company access
- Sees all 19 operational lots
- Mobile app access only

**Role: user** (default)
- Regular field worker
- Sees ONLY their assigned company's lots
- Mobile app access only

### Authentication Flow

**Mobile App:**
1. User logs in with email/password
2. POST to `/api/mobile/users/login` with base64-encoded password
3. Backend validates and returns JWT token + user details
4. Token stored in SharedPreferences
5. All subsequent requests include token in Authorization header

**Web Dashboard:**
1. Uses Manus OAuth for SSO
2. Callback at `/api/oauth/callback`
3. Session cookie stored
4. tRPC context includes user info

---

## 🚀 Deployment Workflow

### Backend Deployment (Current Method)

**Step 1: Build Locally**
```bash
cd /home/ubuntu/mottainai-admin-dashboard
pnpm install
pnpm build
```

**Step 2: Package for Deployment**
```bash
tar -czf backend-deploy.tar.gz dist/ server/ package.json pnpm-lock.yaml
```

**Step 3: Upload to Production**
```bash
sshpass -p 'Shams117@@@@' scp backend-deploy.tar.gz root@172.232.24.180:/root/
```

**Step 4: Extract and Restart**
```bash
sshpass -p 'Shams117@@@@' ssh root@172.232.24.180 "
  cd /root/mottainai-dashboard &&
  tar -xzf ../backend-deploy.tar.gz &&
  pnpm install --prod &&
  pm2 restart mottainai-dashboard
"
```

**Step 5: Verify**
```bash
curl https://admin.kowope.xyz/api/trpc/lots.list
```

### Mobile App Build (Current Method)

**Build on Production Server** (has Android SDK)

**Step 1: Package Source**
```bash
cd /home/ubuntu
tar -czf mobile-app.tar.gz \
  --exclude='mottainai_survey_app/build' \
  --exclude='mottainai_survey_app/.dart_tool' \
  mottainai_survey_app/
```

**Step 2: Upload to Build Server**
```bash
sshpass -p 'Shams117@@@@' scp mobile-app.tar.gz root@172.232.24.180:/root/
```

**Step 3: Build APK**
```bash
sshpass -p 'Shams117@@@@' ssh root@172.232.24.180 "
  cd /root &&
  rm -rf build-temp &&
  tar -xzf mobile-app.tar.gz &&
  mv mottainai_survey_app build-temp &&
  cd build-temp &&
  export ANDROID_HOME=/opt/android-sdk &&
  export JAVA_HOME=/opt/jdk-17.0.2 &&
  /opt/flutter/bin/flutter clean &&
  /opt/flutter/bin/flutter pub get &&
  /opt/flutter/bin/flutter build apk --release
"
```

**Step 4: Download APK**
```bash
sshpass -p 'Shams117@@@@' scp \
  root@172.232.24.180:/root/build-temp/build/app/outputs/flutter-apk/app-release.apk \
  /home/ubuntu/mottainai-v{VERSION}.apk
```

---

## 📡 API Endpoints Reference

### Mobile App Endpoints

**Login**
```
POST /api/mobile/users/login
Content-Type: application/json

Request:
{
  "email": "user@example.com",
  "password": "base64_encoded_password"
}

Response:
{
  "success": true,
  "token": "jwt_token",
  "user": {
    "id": "user_id",
    "email": "user@example.com",
    "name": "User Name",
    "role": "user",
    "companyId": "company_id"
  }
}
```

**Get Lots (tRPC Batch Format)**
```
GET /api/trpc/lots.list?batch=1&input={"0":{"json":{"userId":"USER_ID"}}}

Response:
[{
  "result": {
    "data": {
      "json": {
        "lots": [...],
        "totalCount": 19,
        "userRole": "cherry_picker",
        "message": "Showing all 19 operational lots"
      }
    }
  }
}]
```

### Web Dashboard Endpoints (tRPC)

- `auth.me` - Get current user
- `auth.logout` - Logout
- `lots.list` - Get filtered lots
- `system.notifyOwner` - Send notification to owner

---

## 🧪 Testing Accounts

### Regular User (URBAN SPIRIT Company)
- **Email**: adeyadewuyi@gmail.com
- **Password**: 123456
- **Role**: user
- **User ID**: 6622b0d1f9f81b0481c7e99f
- **Company**: URBAN SPIRIT (69185eebf21dfa8ce0f9a7aa)
- **Expected Lots**: 1 lot (LOT-6: G R A Ikeja)

### Cherry Picker (All Companies)
- **Email**: cherrypicker.test@mottainai.com
- **Password**: cherry123
- **Role**: cherry_picker
- **User ID**: 691eca4fd94e2c88ad67cbbf
- **Expected Lots**: 19 lots (all operational lots)

### Admin User
- **User ID**: 66212f85df2188147c7a81d7
- **Role**: admin
- **Expected Lots**: 19 lots (all operational lots)

---

## 🐛 Common Issues & Solutions

### Issue: "No companies available" in mobile app
**Cause**: Mobile app trying to load from non-existent `/companies/active` endpoint  
**Solution**: Already fixed in v2.9.5 - companies extracted from lots API

### Issue: "No operational lots available"
**Cause**: User's `companyId` not set or lots missing `companyId` field  
**Solution**: 
```javascript
// Update user's companyId in MongoDB
db.users.updateOne(
  { _id: ObjectId("USER_ID") },
  { $set: { companyId: "COMPANY_ID" } }
)
```

### Issue: Login fails with "FormatException: Unexpected character"
**Cause**: API returning HTML instead of JSON — usually a Nginx routing gap (a path not covered by any location block falls through to the catch-all which proxies to port 3000, which is down)  
**Solution**: Check the active Nginx config at `/etc/nginx/sites-enabled/upwork.kowope.xyz` and ensure the failing path has a `location` block pointing to port 3003. Then `nginx -t && nginx -s reload`.

### Issue: `/api/trpc/lots.list` returns 404 or empty lots
**Cause 1**: Nginx `/api/trpc` block on `admin.kowope.xyz` missing or pointing to wrong port  
**Cause 2**: `mottainai-dashboard` process not running with correct `JWT_SECRET`  
**Cause 3**: `jwtToken.js` on `upwork.kowope.xyz` backend using wrong secret  
**Solution**: Ensure `admin.kowope.xyz` Nginx has `location /api/trpc { proxy_pass http://localhost:3005; }`. Restart dashboard with `JWT_SECRET=mottainai-secret-key-2025`. Ensure `jwtToken.js` uses `process.env.JWT_SECRET || 'mottainai-secret-key-change-in-production'`.

### Issue: PM2 process not starting
**Cause**: MongoDB connection failed or port already in use  
**Solution**:
```bash
# Check PM2 logs
pm2 logs mottainai-dashboard --lines 50

# Restart with fresh environment
pm2 delete mottainai-dashboard
pm2 start dist/index.js --name mottainai-dashboard
pm2 save
```

---

## 📝 Version History

### v3.3.0 (Mobile App — March 30, 2026)
- ✅ Added `arcgisBuildingId` field to `PickupSubmission` model (sent to backend in `/forms/submit`)
- ✅ SQLite schema bumped to v14 with `arcgisBuildingId TEXT` migration
- ✅ Flutter `withOpacity()` compatibility fix (replaced `withValues(alpha:)` calls)
- ✅ APK: `https://upwork.kowope.xyz/mottainai-survey-app-v3.3.0.apk` (24.2 MB)

### v2.3.0 (Backend — March 30, 2026)
- ✅ `POST /customer/synchronize` — writes `lga_name`, `lga_code`, `state_code`, `ward_code`, `ward_name`, `Lat`, `Long` to ArcGIS Customer Layer
- ✅ `POST /customer/triggerGeoBackfill` — bulk backfill endpoint for existing records
- ✅ `customerData` model: added `arcgisBuildingId`, `lgaName`, `lgaCode`, `stateCode`, `country`, `wardCode`, `wardName`
- ✅ `formSubmission` model: added `arcgisBuildingId`, `lotCode`, `lgaName`, `lgaCode`, `stateCode`, `country`, `wardCode`, `wardName`
- ✅ `jwtToken.js` secret aligned with dashboard (`process.env.JWT_SECRET`)
- ✅ Nginx routing fixed on `upwork.kowope.xyz`: `/users`, `/forms`, `/customer`, `/api/trpc`, `/api/mobile/users` all route to port 3003
- ✅ Nginx routing fixed on `admin.kowope.xyz`: `/api/trpc` routes to port 3005
- ✅ APK files served from `/var/www/html/` via Nginx `.apk` location block

### v2.9.5 (Backend — November 20, 2025)
- ✅ Fixed company name display in mobile app
- ✅ Extract companies from lots API response
- ✅ Updated OperationalLot model with companyId/companyName fields
- ✅ Uploaded to GitHub repositories

### v2.9.4
- ✅ Removed PIN authentication screen
- ✅ Direct navigation from home to pickup form

### v2.9.3
- ✅ Fixed mobile login API endpoint
- ✅ Created `/api/mobile/users/login` REST endpoint

### v2.9.2
- ✅ Implemented role-based lot filtering
- ✅ Updated lot service with tRPC batch format
- ✅ Added user-specific lot caching (24 hours)

---

## 🔄 Maintenance Tasks

### Regular Maintenance

**Weekly:**
- Check PM2 process status: `pm2 status`
- Review error logs: `pm2 logs mottainai-dashboard --err --lines 100`
- Monitor MongoDB connection health

**Monthly:**
- Update dependencies: `pnpm update`
- Review and clean old APK builds
- Backup MongoDB database

**As Needed:**
- Add new lots via admin dashboard or MongoDB
- Create new user accounts
- Update webhook URLs for companies

### Adding New Operational Lot

**Option 1: Via MongoDB**
```javascript
db.lots.insertOne({
  lotCode: "LOT-20",
  lotName: "New Location Name",
  companyId: "company_id_here",
  companyName: "COMPANY NAME",
  paytWebhook: "https://upwork.kowope.xyz/survey/SPL_xxx/SPL_xxx",
  monthlyWebhook: "https://upwork.kowope.xyz/survey/monthly/SPL_xxx/SPL_xxx",
  isActive: true
})
```

**Option 2: Via activeLots.json** (legacy method)
Update `/home/ubuntu/mottainai-admin-dashboard/activeLots.json` and redeploy

### Adding New User

```javascript
// Hash password first with bcrypt
const bcrypt = require('bcrypt');
const hashedPassword = await bcrypt.hash('plain_password', 10);

db.users.insertOne({
  email: "newuser@example.com",
  password: hashedPassword,
  name: "New User Name",
  role: "user",  // or "cherry_picker" or "admin"
  companyId: "company_id_here",
  createdAt: new Date(),
  updatedAt: new Date()
})
```

---

## 🎯 Quick Reference Commands

### SSH to Production
```bash
sshpass -p 'Shams117@@@@' ssh root@172.232.24.180
```

### Check Backend Status
```bash
pm2 status
pm2 logs mottainai-dashboard --lines 50
```

### Test API Endpoints
```bash
# Test lots API
curl 'https://admin.kowope.xyz/api/trpc/lots.list?batch=1&input=%7B%220%22%3A%7B%22json%22%3A%7B%22userId%22%3A%22USER_ID%22%7D%7D%7D'

# Test login API
curl -X POST https://admin.kowope.xyz/api/mobile/users/login \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"BASE64_PASSWORD"}'
```

### Build Mobile APK
```bash
cd /home/ubuntu/mottainai_survey_app
flutter clean
flutter pub get
flutter build apk --release
```

### Update GitHub
```bash
# Backend
cd /home/ubuntu/mottainai-admin-dashboard
git add .
git commit -m "Description of changes"
git push origin main

# Mobile App
cd /home/ubuntu/mottainai_survey_app
git add .
git commit -m "Description of changes"
git push origin main
```

---

## 📞 Important Contacts & Resources

### Production Infrastructure
- **Server IP**: 172.232.24.180
- **Domain**: admin.kowope.xyz
- **SSL**: Managed via server (check with hosting provider)

### Development Tools
- **MongoDB Compass**: For database management
- **Postman**: For API testing
- **Android Studio**: For mobile app debugging
- **VS Code**: For code editing

### External Services
- **ArcGIS**: Building polygon data
- **Manus Platform**: OAuth and hosting
- **GitHub**: Code repository

---

## 🚨 Emergency Procedures

### Backend Down
1. SSH to production: `ssh root@172.232.24.180`
2. Check PM2: `pm2 status`
3. Check logs: `pm2 logs mottainai-dashboard --err --lines 100`
4. Restart: `pm2 restart mottainai-dashboard`
5. If still down, check MongoDB connection

### Database Connection Lost
1. Verify MongoDB URI is correct
2. Check MongoDB server status with hosting provider
3. Test connection: `mongo "mongodb://..."`
4. Restart backend after connection restored

### Mobile App Crashes
1. Check backend API is accessible
2. Review app logs on device
3. Verify user credentials are valid
4. Check lot data is loading correctly
5. Clear app cache and retry

---

## 💡 Key Design Decisions

### Why Role-Based Filtering?
- **Security**: Users can't access other companies' data
- **Scalability**: Easy to add new roles without code changes
- **Flexibility**: Cherry pickers need cross-company access

### Why tRPC Batch Format?
- **Type Safety**: End-to-end TypeScript types
- **Efficiency**: Multiple queries in single request
- **Standard**: Official tRPC format for HTTP transport

### Why Separate Mobile Auth Endpoint?
- **Compatibility**: Mobile apps expect REST, not tRPC
- **Simplicity**: Easier for mobile developers to integrate
- **Flexibility**: Can add mobile-specific features

### Why Build APK on Production Server?
- **Android SDK**: Requires large SDK installation (~4GB)
- **Build Time**: Faster on dedicated server
- **Consistency**: Same build environment every time

---

## 📚 Documentation Files

All documentation is stored in `/home/ubuntu/` and GitHub repositories:

- `MOTTAINAI_PROJECT_MEMORY.md` - This file (complete reference)
- `MOBILE_APP_ROLE_BASED_API.md` - Mobile API integration guide
- `DEPLOYMENT_SUCCESS_SUMMARY.md` - Deployment verification
- `GITHUB_REPOSITORIES_SUMMARY.md` - GitHub setup details
- `MOTTAINAI_V2.9.5_RELEASE_NOTES.md` - Latest release notes

---

## 🔮 Future Enhancements

### Planned Features
- [ ] Real-time pickup tracking
- [ ] Push notifications for field workers
- [ ] Analytics dashboard for pickup metrics
- [ ] Automated lot assignment based on GPS
- [ ] Multi-language support

### Technical Improvements
- [ ] Set up CI/CD pipeline with GitHub Actions
- [ ] Implement automated testing (unit + integration)
- [ ] Add database backups automation
- [ ] Set up monitoring and alerting
- [ ] Implement rate limiting on API endpoints

---

**This document serves as the complete memory for the Mottainai project. Keep it updated with any significant changes to architecture, deployment, or workflows.**

**Last Verified**: March 30, 2026  
**Next Review**: When major changes occur or monthly
