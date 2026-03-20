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
      version: 12,
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
      socioClass $textNullable
    )
    ''');

    await db.execute('''
    CREATE TABLE cached_polygons (
      buildingId $textType,
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

    // Create index for faster spatial queries
    await db.execute('''
    CREATE INDEX idx_polygon_location ON cached_polygons(centerLat, centerLon)
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 12) {
      // Clear cached polygons - v3.2.20:
      // Force re-sync after polygon tap + label fixes.
      // Old cache is valid but a fresh sync ensures labels render correctly.
      await db.execute('DELETE FROM cached_polygons');
      print('Cleared polygon cache: forcing re-sync after v3.2.20 tap+label fixes');
    }

    if (oldVersion < 11) {
      // Clear cached polygons - v3.2.18:
      // Force re-sync centred on current GPS location.
      // Old cache may have polygons from a different location (previous session).
      await db.execute('DELETE FROM cached_polygons');
      print('Cleared polygon cache: forcing re-sync at current GPS location (v3.2.18)');
    }

    if (oldVersion < 10) {
      // Clear cached polygons - v3.2.10 fixes:
      // 1. Longitude delta formula (cos(lat) instead of lat/90)
      // 2. Radius increased from 500m to 1km
      // Old cache may have polygons from wrong area due to broken bounding box query
      await db.execute('DELETE FROM cached_polygons');
      print('Cleared polygon cache: fixing bounding box formula and radius (v3.2.10)');
    }

    if (oldVersion < 9) {
      // Clear cached polygons - v3.2.8 fixes coordinate projection (outSR=4326)
      // Old cache has wrong coordinates (local Nigerian projection, ~80km off)
      await db.execute('DELETE FROM cached_polygons');
      print('Cleared polygon cache: coordinates were in wrong projection (v3.2.8 fix)');
    }

    if (oldVersion < 8) {
      // Add customer contact columns to pickups table (v3.2.5)
      const textNullable = 'TEXT';
      for (final col in ['customerName', 'customerPhone', 'customerEmail', 'customerAddress']) {
        try {
          await db.execute('ALTER TABLE pickups ADD COLUMN $col $textNullable');
          print('Successfully added $col column to pickups table');
        } catch (e) {
          print('Error adding $col column (may already exist): $e');
        }
      }
    }

    if (oldVersion < 7) {
      // Add socioClass column to pickups table
      const textNullable = 'TEXT';
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN socioClass $textNullable');
        print('Successfully added socioClass column to pickups table');
      } catch (e) {
        print('Error adding socioClass column: $e');
      }
    }
    
    if (oldVersion < 6) {
      // Add customerLabels column to cached_polygons table
      const textNullable = 'TEXT';
      try {
        await db.execute('ALTER TABLE cached_polygons ADD COLUMN customerLabels $textNullable');
      } catch (e) {
        print('Error adding customerLabels column: $e');
      }
    }
    
    if (oldVersion < 5) {
      // Add company fields to pickups table
      const textNullable = 'TEXT';
      try {
        await db.execute('ALTER TABLE pickups ADD COLUMN companyId $textNullable');
        await db.execute('ALTER TABLE pickups ADD COLUMN companyName $textNullable');
        await db.execute('ALTER TABLE pickups ADD COLUMN lotCode $textNullable');
        await db.execute('ALTER TABLE pickups ADD COLUMN lotName $textNullable');
      } catch (e) {
        print('Error adding company columns: $e');
      }
    }
    
    if (oldVersion < 3) {
      // Add polygon cache table
      const textType = 'TEXT NOT NULL';
      const textNullable = 'TEXT';
      
      await db.execute('''
      CREATE TABLE cached_polygons (
        buildingId $textType,
        businessName $textNullable,
        custPhone $textNullable,
        customerEmail $textNullable,
        address $textNullable,
        zone $textNullable,
        socioEconomicGroups $textNullable,
        geometry $textType,
        centerLat REAL NOT NULL,
        centerLon REAL NOT NULL,
        lastUpdated INTEGER NOT NULL
      )
      ''');

      await db.execute('''
      CREATE INDEX idx_polygon_location ON cached_polygons(centerLat, centerLon)
      ''');
    }
    
    if (oldVersion < 4) {
      // Clear polygon cache to force re-sync with corrected JSON format
      await db.execute('DELETE FROM cached_polygons');
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

  // ========== Polygon Cache Methods ==========
  
  Future<int> cachePolygon(Map<String, dynamic> polygon) async {
    final db = await instance.database;
    // Delete existing polygon with same buildingId
    await db.delete(
      'cached_polygons',
      where: 'buildingId = ?',
      whereArgs: [polygon['buildingId']],
    );
    return await db.insert('cached_polygons', polygon);
  }

  Future<void> cachePolygons(List<Map<String, dynamic>> polygons) async {
    final db = await instance.database;
    final batch = db.batch();
    
    for (var polygon in polygons) {
      // Delete existing
      batch.delete(
        'cached_polygons',
        where: 'buildingId = ?',
        whereArgs: [polygon['buildingId']],
      );
      // Insert new
      batch.insert('cached_polygons', polygon);
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

  /// Get polygons within approximate radius (simple bounding box query)
  /// For production, consider using a proper spatial database or R-tree index
  Future<List<Map<String, dynamic>>> getPolygonsNearLocation({
    required double lat,
    required double lon,
    double radiusKm = 1.0,
  }) async {
    final db = await instance.database;
    
    // Approximate degrees for radius (1 degree ≈ 111km at equator)
    // Latitude delta is constant; longitude delta shrinks toward the poles via cos(lat)
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
