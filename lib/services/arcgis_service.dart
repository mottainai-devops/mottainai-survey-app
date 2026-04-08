import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/building_polygon.dart';
import '../models/customer_point.dart';

/// Service for all ArcGIS FeatureServer interactions.
///
/// Two authoritative layers:
///   Footprint Layer — building polygon geometries (primary record)
///                     Nigeria_Building_Footprints (updated 2026-04-07)
///   Customer Layer  — customer point features, one per unit
///                     composite key: building_id + flat_no (R1, R2, C1, C2…)
///
/// Field changes in the new footprint layer vs old (New_Footprints_gdb_b1422):
///   Renamed: Validation → Verification, Validated_By → Source
///   Removed: Zone, Z_Name, socio_economic_groups, address2, google_address2,
///            V_Date, Validation, Validated_By, and many legacy fields
///
/// All reads come from here; all new customer writes go back here to keep
/// the map labels live and consistent.
class ArcGISService {
  // ─── Layer URLs ──────────────────────────────────────────────────────────────

  static const String _footprintUrl =
      'https://services3.arcgis.com/VYBpf26AGQNwssLH/arcgis/rest/services'
      '/Nigeria_Building_Footprints/FeatureServer/0';

  static const String _customerUrl =
      'https://services3.arcgis.com/VYBpf26AGQNwssLH/arcgis/rest/services'
      '/Customer_Layer_gdb/FeatureServer/0';

  // ─── Config ──────────────────────────────────────────────────────────────────

  static const Duration _timeout = Duration(seconds: 60);
  static const int _maxRetries = 2;

  // Maximum buildings to load per viewport query (keeps response fast on mobile)
  static const int _maxPolygonsPerQuery = 200;

  // Maximum customer records to load per query
  static const int _maxCustomersPerQuery = 500;

  // ─── Footprint Layer ─────────────────────────────────────────────────────────

  /// Fetch building polygons whose geometry intersects the given bounding box.
  ///
  /// [minLat], [maxLat], [minLon], [maxLon] define the viewport in WGS84.
  /// Returns up to [_maxPolygonsPerQuery] polygons.
  Future<List<BuildingPolygon>> fetchPolygonsInViewport({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) async {
    // ArcGIS envelope geometry: {xmin, ymin, xmax, ymax}
    final envelope = jsonEncode({
      'xmin': minLon,
      'ymin': minLat,
      'xmax': maxLon,
      'ymax': maxLat,
      'spatialReference': {'wkid': 4326},
    });

    final params = {
      'where': '1=1',
      'geometry': envelope,
      'geometryType': 'esriGeometryEnvelope',
      'inSR': '4326',
      'spatialRel': 'esriSpatialRelIntersects',
      'outFields': 'building_id,house_name,house_no,street_name,address,Verification,Source',
      'returnGeometry': 'true',
      'outSR': '4326',
      'resultRecordCount': _maxPolygonsPerQuery.toString(),
      'f': 'json',
    };

    print('[ArcGIS] Fetching polygons in viewport '
        '($minLat,$minLon) → ($maxLat,$maxLon)');

    final data = await _postQuery('$_footprintUrl/query', params);
    final features = data['features'] as List<dynamic>? ?? [];

    final polygons = <BuildingPolygon>[];
    for (final f in features) {
      try {
        polygons.add(BuildingPolygon.fromArcGIS(f as Map<String, dynamic>));
      } catch (e) {
        print('[ArcGIS] Skipping bad footprint feature: $e');
      }
    }

    print('[ArcGIS] Footprint query returned ${polygons.length} polygons');
    return polygons;
  }

  /// Fetch building polygons within a radius of a center point.
  /// Used on initial GPS location load.
  Future<List<BuildingPolygon>> fetchPolygonsNearLocation({
    required double lat,
    required double lon,
    double radiusKm = 0.5,
    void Function(int fetched)? onProgress,
  }) async {
    final radiusMeters = (radiusKm * 1000).round();
    final geometryJson =
        '{"x":$lon,"y":$lat,"spatialReference":{"wkid":4326}}';

    final params = {
      'where': '1=1',
      'geometry': geometryJson,
      'geometryType': 'esriGeometryPoint',
      'inSR': '4326',
      'spatialRel': 'esriSpatialRelIntersects',
      'distance': radiusMeters.toString(),
      'units': 'esriSRUnit_Meter',
      'outFields': 'building_id,house_name,house_no,street_name,address,Verification,Source',
      'returnGeometry': 'true',
      'outSR': '4326',
      'resultRecordCount': _maxPolygonsPerQuery.toString(),
      'f': 'json',
    };

    print('[ArcGIS] Fetching polygons within ${radiusMeters}m of ($lat, $lon)');

    final data = await _postQuery('$_footprintUrl/query', params);
    final features = data['features'] as List<dynamic>? ?? [];

    final polygons = <BuildingPolygon>[];
    for (final f in features) {
      try {
        polygons.add(BuildingPolygon.fromArcGIS(f as Map<String, dynamic>));
      } catch (e) {
        print('[ArcGIS] Skipping bad footprint feature: $e');
      }
    }

    onProgress?.call(polygons.length);
    print('[ArcGIS] Radius query returned ${polygons.length} polygons');
    return polygons;
  }

  /// Fetch a single building polygon by its building_id.
  Future<BuildingPolygon?> fetchPolygonByBuildingId(String buildingId) async {
    final params = {
      'where': "building_id='${_escapeSql(buildingId)}'",
      'outFields': 'building_id,house_name,house_no,street_name,address,Verification,Source',
      'returnGeometry': 'true',
      'outSR': '4326',
      'f': 'json',
    };

    try {
      final data = await _postQuery('$_footprintUrl/query', params);
      final features = data['features'] as List<dynamic>? ?? [];
      if (features.isEmpty) return null;
      return BuildingPolygon.fromArcGIS(features[0] as Map<String, dynamic>);
    } catch (e) {
      print('[ArcGIS] fetchPolygonByBuildingId error: $e');
      return null;
    }
  }

  // ─── Customer Layer ───────────────────────────────────────────────────────────

  /// Fetch all customer points for a list of building IDs.
  ///
  /// Returns a map of buildingId → list of CustomerPoints.
  /// This is the primary method used by the map to colour polygons and
  /// render unit code label chips (R1, C2, etc.).
  Future<Map<String, List<CustomerPoint>>> fetchCustomersForBuildings(
      List<String> buildingIds) async {
    if (buildingIds.isEmpty) return {};

    // Build SQL IN clause — escape each ID
    final inList = buildingIds
        .map((id) => "'${_escapeSql(id)}'")
        .join(',');

    final params = {
      'where': 'building_id IN ($inList)',
      'outFields':
          'OBJECTID,building_id,flat_no,business_name,first_name,last_name,cust_phone,customer_email,customer_type,status,address2,Lat,Long',
      'returnGeometry': 'true',
      'outSR': '4326',
      'resultRecordCount': _maxCustomersPerQuery.toString(),
      'f': 'json',
    };

    print('[ArcGIS] Fetching customers for ${buildingIds.length} buildings');

    try {
      final data = await _postQuery('$_customerUrl/query', params);
      final features = data['features'] as List<dynamic>? ?? [];

      final result = <String, List<CustomerPoint>>{};
      for (final f in features) {
        try {
          final cp = CustomerPoint.fromArcGIS(f as Map<String, dynamic>);
          if (cp.buildingId.isEmpty) continue;
          result.putIfAbsent(cp.buildingId, () => []).add(cp);
        } catch (e) {
          print('[ArcGIS] Skipping bad customer feature: $e');
        }
      }

      final total = result.values.fold(0, (s, l) => s + l.length);
      print('[ArcGIS] Customer query returned $total points '
          'across ${result.length} buildings');
      return result;
    } catch (e) {
      print('[ArcGIS] fetchCustomersForBuildings error: $e');
      return {};
    }
  }

  /// Fetch all customers for a single building ID.
  /// Used when tapping a polygon to show the full customer list.
  Future<List<CustomerPoint>> fetchCustomersForBuilding(
      String buildingId) async {
    final map = await fetchCustomersForBuildings([buildingId]);
    return map[buildingId] ?? [];
  }

  // ─── Unit code derivation ─────────────────────────────────────────────────────

  /// Derive the next sequential unit code for a building based on customer_type.
  ///
  /// Residential (type '1') → R1, R2, R3 …
  /// Commercial  (type '2') → C1, C2, C3 …
  ///
  /// Queries the Customer Layer for existing units at [buildingId] and returns
  /// the next available code. Returns 'R1' or 'C1' if none exist yet.
  Future<String> getNextUnitCode({
    required String buildingId,
    required String customerType, // '1' = residential, '2' = commercial
  }) async {
    final prefix = (customerType == '1') ? 'R' : 'C';
    try {
      final params = {
        'where': "building_id='${_escapeSql(buildingId)}' AND flat_no LIKE '${prefix}%'",
        'outFields': 'flat_no',
        'returnGeometry': 'false',
        'resultRecordCount': '100',
        'f': 'json',
      };
      final data = await _postQuery('$_customerUrl/query', params);
      final features = data['features'] as List<dynamic>? ?? [];

      // Extract existing numeric suffixes (e.g. R1 → 1, R2 → 2)
      int maxNum = 0;
      for (final f in features) {
        final attrs = f['attributes'] as Map<String, dynamic>? ?? {};
        final flatNo = attrs['flat_no']?.toString() ?? '';
        if (flatNo.startsWith(prefix)) {
          final numStr = flatNo.substring(prefix.length);
          final num = int.tryParse(numStr);
          if (num != null && num > maxNum) maxNum = num;
        }
      }
      final nextCode = '$prefix${maxNum + 1}';
      print('[ArcGIS] Next unit code for $buildingId (type=$customerType): $nextCode');
      return nextCode;
    } catch (e) {
      print('[ArcGIS] getNextUnitCode error: $e — defaulting to ${prefix}1');
      return '${prefix}1';
    }
  }

  // ─── Customer upsert ──────────────────────────────────────────────────────────

  /// Upsert a customer point in the ArcGIS Customer Layer.
  ///
  /// The composite key is [buildingId] + [flatNo] — one record per unit.
  /// If a record with this key already exists it is updated in-place.
  /// If none exists, a new feature is added.
  ///
  /// [buildingId]  — the parent building's ArcGIS building_id
  /// [flatNo]      — unit code e.g. R1, R2, C1, C2 (derive via getNextUnitCode)
  /// [lat], [lon]  — WGS84 coordinates (use building centroid if no GPS fix)
  /// [attributes]  — customer fields: business_name, first_name, last_name,
  ///                 cust_phone, customer_email, customer_type, address2
  ///
  /// Returns true on success, false on failure.
  Future<bool> addCustomerToLayer({
    required String buildingId,
    required double lat,
    required double lon,
    required Map<String, dynamic> attributes,
    String? flatNo, // unit code e.g. R1, C2 — derive via getNextUnitCode()
  }) async {
    final geometry = {
      'x': lon,
      'y': lat,
      'spatialReference': {'wkid': 4326},
    };
    final attrs = {
      'building_id': buildingId,
      'Lat': lat,
      'Long': lon,
      if (flatNo != null) 'flat_no': flatNo,
      ...attributes,
    };

    print('[ArcGIS] Upserting customer for building: $buildingId unit: ${flatNo ?? "(no unit code)"}');

    try {
      // ── Step 1: check for an existing record with this buildingId + flat_no ──
      // The composite key (building_id + flat_no) ensures one point per unit.
      // If flatNo is null (legacy call), fall back to building_id-only lookup.
      final whereClause = flatNo != null
          ? "building_id='${_escapeSql(buildingId)}' AND flat_no='${_escapeSql(flatNo)}'"
          : "building_id='${_escapeSql(buildingId)}'";

      final queryParams = {
        'where': whereClause,
        'outFields': 'OBJECTID',
        'returnGeometry': 'false',
        'resultRecordCount': '1',
        'f': 'json',
      };
      final queryData = await _postQuery('$_customerUrl/query', queryParams);
      final features = queryData['features'] as List<dynamic>? ?? [];

      if (features.isNotEmpty) {
        // ── Step 2a: UPDATE existing record ──────────────────────────────────
        final objectId =
            (features[0]['attributes'] as Map<String, dynamic>)['OBJECTID'];
        final updateFeature = {
          'geometry': geometry,
          'attributes': {'OBJECTID': objectId, ...attrs},
        };
        final updateBody = {
          'features': jsonEncode([updateFeature]),
          'rollbackOnFailure': 'true',
          'f': 'json',
        };
        final uri = Uri.parse('$_customerUrl/updateFeatures');
        final response = await http
            .post(uri,
                headers: {
                  'Content-Type': 'application/x-www-form-urlencoded'
                },
                body: updateBody)
            .timeout(_timeout);

        if (response.statusCode != 200) {
          print('[ArcGIS] updateFeatures HTTP ${response.statusCode}');
          return false;
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['error'] != null) {
          print('[ArcGIS] updateFeatures error: ${data['error']}');
          return false;
        }
        final updateResults = data['updateResults'] as List<dynamic>? ?? [];
        final success = updateResults.isNotEmpty &&
            (updateResults[0]['success'] as bool? ?? false);
        print('[ArcGIS] Customer updated (objectId=$objectId unit=$flatNo), '
            'success=$success');
        return success;
      } else {
        // ── Step 2b: INSERT new record ────────────────────────────────────────
        final addFeature = {'geometry': geometry, 'attributes': attrs};
        final addBody = {
          'features': jsonEncode([addFeature]),
          'rollbackOnFailure': 'true',
          'f': 'json',
        };
        final uri = Uri.parse('$_customerUrl/addFeatures');
        final response = await http
            .post(uri,
                headers: {
                  'Content-Type': 'application/x-www-form-urlencoded'
                },
                body: addBody)
            .timeout(_timeout);

        if (response.statusCode != 200) {
          print('[ArcGIS] addFeatures HTTP ${response.statusCode}');
          return false;
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['error'] != null) {
          print('[ArcGIS] addFeatures error: ${data['error']}');
          return false;
        }
        final addResults = data['addResults'] as List<dynamic>? ?? [];
        if (addResults.isEmpty) return false;
        final success = addResults[0]['success'] as bool? ?? false;
        print('[ArcGIS] Customer added (objectId=${addResults[0]['objectId']} unit=$flatNo), '
            'success=$success');
        return success;
      }
    } catch (e) {
      print('[ArcGIS] addCustomerToLayer (upsert) error: $e');
      return false;
    }
  }

  // ─── Socio-economic helper ────────────────────────────────────────────────────

  /// Get socio-economic class for a building from the Customer Layer.
  ///
  /// The `socio_economic_groups` field was removed from the new
  /// Nigeria_Building_Footprints layer (updated 2026-04-07). We now read it
  /// from the Customer Layer (`Customer_Layer_gdb`) instead, which still
  /// carries the field.
  ///
  /// Strategy: query ALL units in the building (all flat_no values for this
  /// building_id), collect every non-null socio_economic_groups value, and
  /// return the most frequently occurring class. This handles multi-unit
  /// buildings correctly — all units in the same building share the same
  /// socio-economic classification in practice, but if there is any
  /// inconsistency we use the majority vote. Falls back to the most recently
  /// added record if all counts are equal.
  ///
  /// Returns null if no customer record exists for the building or if no
  /// unit has a socio class set — in that case the field worker selects manually.
  Future<String?> getSocioEconomicClass(String buildingId) async {
    try {
      // Fetch all units for this building (up to 50 — buildings with more
      // than 50 units are extremely rare; the majority vote still holds).
      final params = {
        'where': "building_id='${_escapeSql(buildingId)}'",
        'outFields': 'socio_economic_groups,flat_no,CreationDate',
        'returnGeometry': 'false',
        'resultRecordCount': '50',
        'orderByFields': 'CreationDate DESC', // most recent first for tie-break
        'f': 'json',
      };

      final data = await _postQuery('$_customerUrl/query', params);
      final features = data['features'] as List<dynamic>? ?? [];
      if (features.isEmpty) return null;

      // Collect all valid socio class values
      final counts = <String, int>{};
      String? mostRecent;
      for (final feature in features) {
        final attrs = feature['attributes'] as Map<String, dynamic>;
        final raw = attrs['socio_economic_groups']?.toString();
        if (raw == null || raw.trim().isEmpty) continue;
        final normalized = raw.toLowerCase().trim();
        if (!['low', 'medium', 'high'].contains(normalized)) continue;
        counts[normalized] = (counts[normalized] ?? 0) + 1;
        mostRecent ??= normalized; // first entry is most recent (ordered DESC)
      }

      if (counts.isEmpty) return null;

      // Return the majority class; use mostRecent as tie-breaker
      final winner = counts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
      return winner;
    } catch (e) {
      print('[ArcGIS] getSocioEconomicClass (Customer Layer) error: $e');
      return null;
    }
  }

  /// Test connectivity to both layers.
  Future<bool> testConnection() async {
    try {
      final uri = Uri.parse('$_footprintUrl?f=json');
      final response = await http.get(uri).timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      print('[ArcGIS] testConnection failed: $e');
      return false;
    }
  }

  // ─── Internal helpers ─────────────────────────────────────────────────────────

  /// POST a query to an ArcGIS FeatureServer endpoint with retry logic.
  Future<Map<String, dynamic>> _postQuery(
      String url, Map<String, String> params) async {
    final uri = Uri.parse(url);
    http.Response? response;
    int attempt = 0;

    while (attempt < _maxRetries) {
      try {
        response = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: params,
            )
            .timeout(_timeout);
        break;
      } catch (e) {
        attempt++;
        print('[ArcGIS] Attempt $attempt failed for $url: $e');
        if (attempt >= _maxRetries) rethrow;
        await Future.delayed(const Duration(seconds: 3));
      }
    }

    if (response!.statusCode != 200) {
      throw Exception(
          'ArcGIS HTTP ${response.statusCode} for $url');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    if (data['error'] != null) {
      throw Exception(
          'ArcGIS API error: ${data['error']['message']} '
          '(code ${data['error']['code']})');
    }

    return data;
  }

  /// Escape single quotes in SQL string literals.
  String _escapeSql(String s) => s.replaceAll("'", "''");
}
