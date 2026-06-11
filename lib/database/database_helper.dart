import 'dart:math' as math;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/pickup_submission.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('mottainai.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 17,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future _createDB(Database db, int version) async {
    const idType = 'INTEGER PRIMARY KEY AUTOINCREMENT';
    const textType = 'TEXT NOT NULL';
    const intType = 'INTEGER NOT NULL';
    const textNullable = 'TEXT';

    await db.execute('''
    CREATE TABLE pickups (
      id $idType,
      formId $textType,
      supervisorId $textType,
      customerName $textNullable,
      customerPhone $textNullable,
      customerEmail $textNullable,
      customerAddress $textNullable,
      customerType $textType,
      binType $textType,
      wheelieBinType $textNullable,
      binQuantity $intType,
      buildingId $textType,
      pickUpDate $textType,
      firstPhoto $textType,
      secondPhoto $textType,
      incidentReport $textNullable,
      userId $textType,
      latitude REAL,
      longitude REAL,
      synced INTEGER NOT NULL DEFAULT 0,
      createdAt $textType,
      companyId $textNullable,
      companyName $textNullable,
      lotCode $textNullable,
      lotName $textNullable,
      socioClass $textNullable,
      arcgisBuildingId $textNullable,
      userIdentificationNumber $textNullable,
      unitCode $textNullable,
      customerId $textNullable
    )
    ''');

    await db.execute('''
    CREATE TABLE cached_polygons (
      buildingId $textType PRIMARY KEY,
      businessName $textNullable,
      custPhone $textNullable,
      customerEmail $textNullable,
      address $textNullable,
      zone $textNullable,
      socioEconomicGroups $textNullable,
      geometry $textType,
      centerLat REAL NOT NULL,
      centerLon REAL NOT NULL,
      lastUpdated INTEGER NOT NULL,
      customerLabels $textNullable
    )
    ''');

    // Spatial index for fast bounding box queries
    await db.execute('''
    CREATE INDEX idx_polygon_location ON cached_polygons(centerLat, centerLon)
    ''');

    // v17: Pickup form draft persistence table.
    // Stores a single in-progress form draft so the "before photo" path and all
    // filled fields survive an OS kill or background eviction during a long session.
    await db.execute('''
    CREATE TABLE pickup_drafts (
      id $idType,
      firstPhotoPath $textNullable,
      secondPhotoPath $textNullable,
      supervisorId $textNullable,
      buildingId $textNullable,
      businessName $textNullable,
      customerPhone $textNullable,
      customerEmail $textNullable,
      customerAddress $textNullable,
      binType $textNullable,
      wheelieBinType $textNullable,
      binQuantity $textNullable,
      incidentReport $textNullable,
      customerType $textNullable,
      billingType $textNullable,
      socioClass $textNullable,
      companyId $textNullable,
      companyName $textNullable,
      lotCode $textNullable,
      lotName $textNullable,
      pickUpDate $textNullable,
      latitude REAL,
      longitude REAL,
      savedAt $textType
    )
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v17: Add pickup_drafts table for form draft persistence.
    // This prevents loss of the "before photo" path when the OS kills the app
    // or evicts it from memory during a long pickup session.
    if (oldVersion < 17) {
      try {
        await db.execute('''
        CREATE TABLE IF NOT EXISTS pickup_drafts (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          firstPhotoPath TEXT,
          secondPhotoPath TEXT,
          supervisorId TEXT,
          buildingId TEXT,
          businessName TEXT,
          customerPhone TEXT,
          customerEmail TEXT,
          customerAddress TEXT,
          binType TEXT,
          wheelieBinType TEXT,
          binQuantity TEXT,
          incidentReport TEXT,
          customerType TEXT,
          billingType TEXT,
          socioClass TEXT,
          companyId TEXT,
          companyName TEXT,
          lotCode TEXT,
          lotName TEXT,
          pickUpDate TEXT,
          latitude REAL,
          longitude REAL,
          savedAt TEXT NOT NULL
        )
        ''');
        print('v17 migration: created pickup_drafts table');
      } catch (e) {
        print('pickup_drafts table may already exist: $e');
      }
    }

    // v16: Add unitCode and customerId columns to pickups table (ArcGIS-native identity v3.5.0).
    if (oldVersion < 16) {
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN unitCode TEXT');
        print('v16 migration: added unitCode column to pickups');
      } catch (e) {
        print('unitCode column may already exist: $e');
      }
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN customerId TEXT');
        print('v16 migration: added customerId column to pickups');
      } catch (e) {
        print('customerId column may already exist: $e');
      }
    }

    // v15: Add userIdentificationNumber column to pickups table (GIS Step 2.2).
    if (oldVersion < 15) {
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN userIdentificationNumber TEXT');
        print('v15 migration: added userIdentificationNumber column to pickups');
      } catch (e) {
        print('userIdentificationNumber column may already exist: $e');
      }
    }

    // v14: Add arcgisBuildingId column to pickups table.
    if (oldVersion < 14) {
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN arcgisBuildingId TEXT');
        print('v14 migration: added arcgisBuildingId column to pickups');
      } catch (e) {
        print('arcgisBuildingId column may already exist: $e');
      }
    }

    // v13: Add PRIMARY KEY to buildingId so INSERT OR REPLACE works correctly.
    // This requires recreating the table.
    if (oldVersion < 13) {
      await db.execute('DROP TABLE IF EXISTS cached_polygons');
      await db.execute('''
      CREATE TABLE cached_polygons (
        buildingId TEXT NOT NULL PRIMARY KEY,
        businessName TEXT,
        custPhone TEXT,
        customerEmail TEXT,
        address TEXT,
        zone TEXT,
        socioEconomicGroups TEXT,
        geometry TEXT NOT NULL,
        centerLat REAL NOT NULL,
        centerLon REAL NOT NULL,
        lastUpdated INTEGER NOT NULL,
        customerLabels TEXT
      )
      ''');
      await db.execute('''
      CREATE INDEX idx_polygon_location ON cached_polygons(centerLat, centerLon)
      ''');
      print('v13 migration: recreated cached_polygons with PRIMARY KEY on buildingId');
    }

    if (oldVersion < 8) {
      const textNullable = 'TEXT';
      for (final col in ['customerName', 'customerPhone', 'customerEmail', 'customerAddress']) {
        try {
          await db.execute('ALTER TABLE pickups ADD COLUMN $col $textNullable');
        } catch (e) {
          print('Column $col may already exist: $e');
        }
      }
    }

    if (oldVersion < 7) {
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN socioClass TEXT');
      } catch (e) {
        print('socioClass column may already exist: $e');
      }
    }

    if (oldVersion < 5) {
      const textNullable = 'TEXT';
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN companyId $textNullable');
        await db.execute('ALTER TABLE pickups ADD COLUMN companyName $textNullable');
        await db.execute('ALTER TABLE pickups ADD COLUMN lotCode $textNullable');
        await db.execute('ALTER TABLE pickups ADD COLUMN lotName $textNullable');
      } catch (e) {
        print('Company columns may already exist: $e');
      }
    }
  }

  Future<int> createPickup(PickupSubmission pickup) async {
    final db = await instance.database;
    return await db.insert('pickups', pickup.toMap());
  }

  Future<List<PickupSubmission>> getAllPickups() async {
    final db = await instance.database;
    final result = await db.query('pickups', orderBy: 'createdAt DESC');
    return result.map((json) => PickupSubmission.fromMap(json)).toList();
  }

  Future<List<PickupSubmission>> getUnsyncedPickups() async {
    final db = await instance.database;
    final result = await db.query(
      'pickups',
      where: 'synced = ?',
      whereArgs: [0],
    );
    return result.map((json) => PickupSubmission.fromMap(json)).toList();
  }

  Future<int> markAsSynced(int id) async {
    final db = await instance.database;
    return await db.update(
      'pickups',
      {'synced': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Update supervisorId for a stuck submission so it can be retried
  Future<int> updateSupervisorId(int id, String supervisorId) async {
    final db = await instance.database;
    return await db.update(
      'pickups',
      {'supervisorId': supervisorId},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Update unitCode and customerId on a pickup record after ArcGIS unit code resolution.
  /// Used by pickup_form_screen_v2 to backfill the ArcGIS-native composite Customer ID
  /// ("${arcgisBuildingId} ${unitCode}") on new-customer pickups (Path B).
  Future<int> updatePickupIdentity({
    required String formId,
    required String createdAt,
    required String unitCode,
    required String customerId,
  }) async {
    final db = await instance.database;
    return await db.update(
      'pickups',
      {'unitCode': unitCode, 'customerId': customerId},
      where: 'formId = ? AND createdAt = ?',
      whereArgs: [formId, createdAt],
    );
  }

  Future<int> deletePickup(int id) async {
    final db = await instance.database;
    return await db.delete(
      'pickups',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> getUnsyncedCount() async {
    final db = await instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM pickups WHERE synced = 0',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ========== Draft Persistence Methods (v17) ==========
  //
  // A single row in pickup_drafts represents the current in-progress form state.
  // The table is designed for at most one row at a time (the active draft).
  // On every save the table is cleared and re-inserted so there is never more
  // than one draft row.

  /// Persist the current form state as a draft so it can be recovered after
  /// an OS kill or background eviction.  Call this whenever a photo is captured
  /// and whenever the app goes to background (AppLifecycleState.paused).
  Future<void> saveDraft(Map<String, dynamic> draftData) async {
    final db = await instance.database;
    // Delete any existing draft first (only one draft at a time)
    await db.delete('pickup_drafts');
    draftData['savedAt'] = DateTime.now().toIso8601String();
    await db.insert('pickup_drafts', draftData);
    print('[Draft] Draft saved at ${draftData['savedAt']}');
  }

  /// Load the most recently saved draft, or null if none exists.
  Future<Map<String, dynamic>?> loadDraft() async {
    final db = await instance.database;
    final result = await db.query(
      'pickup_drafts',
      orderBy: 'savedAt DESC',
      limit: 1,
    );
    if (result.isNotEmpty) {
      print('[Draft] Draft loaded, savedAt=${result.first['savedAt']}');
      return result.first;
    }
    return null;
  }

  /// Remove the draft after a successful submit or explicit user discard.
  Future<void> clearDraft() async {
    final db = await instance.database;
    final count = await db.delete('pickup_drafts');
    print('[Draft] Draft cleared ($count row(s) removed)');
  }

  // ========== Polygon Cache Methods ==========

  /// Upsert a single polygon using INSERT OR REPLACE (requires PRIMARY KEY on buildingId)
  Future<int> cachePolygon(Map<String, dynamic> polygon) async {
    final db = await instance.database;
    return await db.insert(
      'cached_polygons',
      polygon,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Bulk upsert polygons using INSERT OR REPLACE — much faster than delete+insert
  Future<void> cachePolygons(List<Map<String, dynamic>> polygons) async {
    final db = await instance.database;
    final batch = db.batch();
    for (var polygon in polygons) {
      batch.insert(
        'cached_polygons',
        polygon,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Map<String, dynamic>>> getCachedPolygons() async {
    final db = await instance.database;
    return await db.query('cached_polygons');
  }

  Future<Map<String, dynamic>?> getPolygonByBuildingId(String buildingId) async {
    final db = await instance.database;
    final result = await db.query(
      'cached_polygons',
      where: 'buildingId = ?',
      whereArgs: [buildingId],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  /// Get polygons within approximate radius (bounding box query with spatial index)
  Future<List<Map<String, dynamic>>> getPolygonsNearLocation({
    required double lat,
    required double lon,
    double radiusKm = 5.0,
  }) async {
    final db = await instance.database;

    final latDelta = radiusKm / 111.0;
    final cosLat = math.cos(lat * math.pi / 180.0);
    final lonDelta = radiusKm / (111.0 * (cosLat > 0.001 ? cosLat : 0.001));

    final minLat = lat - latDelta;
    final maxLat = lat + latDelta;
    final minLon = lon - lonDelta;
    final maxLon = lon + lonDelta;

    return await db.query(
      'cached_polygons',
      where: 'centerLat BETWEEN ? AND ? AND centerLon BETWEEN ? AND ?',
      whereArgs: [minLat, maxLat, minLon, maxLon],
    );
  }

  Future<int> clearPolygonCache() async {
    final db = await instance.database;
    return await db.delete('cached_polygons');
  }

  Future<DateTime?> getLastPolygonCacheUpdate() async {
    final db = await instance.database;
    final result = await db.rawQuery(
      'SELECT MAX(lastUpdated) as maxTime FROM cached_polygons',
    );

    if (result.isNotEmpty && result.first['maxTime'] != null) {
      final timestamp = result.first['maxTime'] as int;
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    return null;
  }

  Future<int> getPolygonCacheCount() async {
    final db = await instance.database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM cached_polygons',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future close() async {
    final db = await instance.database;
    db.close();
  }
}
