import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/building_polygon.dart';
import '../models/customer_point.dart';

/// Service for all ArcGIS FeatureServer interactions.
///
/// Two authoritative layers:
///   Footprint Layer — building polygon geometries
///   Customer Layer  — customer point features (child of footprint)
///
/// Both layers are the single source of truth. All reads come from here;
/// all new customer writes go back here (addFeatures) to keep the map live.
class ArcGISService {
  // ─── Layer URLs ──────────────────────────────────────────────────────────────

  static const String _footprintUrl =
      'https://services3.arcgis.com/VYBpf26AGQNwssLH/arcgis/rest/services'
      '/New_Footprints_gdb_b1422/FeatureServer/0';

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
      'outFields': 'building_id,house_name,house_no,street_name,address2,google_address2,Z_Name,Zone',
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
      'outFields': 'building_id,house_name,house_no,street_name,address2,google_address2,Z_Name,Zone',
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
      'outFields': 'building_id,house_name,house_no,street_name,address2,google_address2,Z_Name,Zone',
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
  /// render customer name label chips.
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
          'OBJECTID,building_id,business_name,first_name,last_name,cust_phone,customer_email,customer_type,status,address2,Lat,Long',
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

  /// Add a new customer point to the ArcGIS Customer Layer.
  ///
  /// Call this after a successful form submission to keep the map live.
  /// [buildingId] — the parent building's ID
  /// [lat], [lon] — WGS84 coordinates (use building centroid if no GPS fix)
  /// [attributes] — customer fields: business_name, first_name, last_name,
  ///                cust_phone, customer_email, customer_type, address2
  ///
  /// Returns true on success, false on failure.
  Future<bool> addCustomerToLayer({
    required String buildingId,
    required double lat,
    required double lon,
    required Map<String, dynamic> attributes,
  }) async {
    final feature = {
      'geometry': {
        'x': lon,
        'y': lat,
        'spatialReference': {'wkid': 4326},
      },
      'attributes': {
        'building_id': buildingId,
        'Lat': lat,
        'Long': lon,
        ...attributes,
      },
    };

    final body = {
      'features': jsonEncode([feature]),
      'rollbackOnFailure': 'true',
      'f': 'json',
    };

    print('[ArcGIS] Adding customer to layer for building: $buildingId');

    try {
      final uri = Uri.parse('$_customerUrl/addFeatures');
      final response = await http
          .post(uri,
              headers: {'Content-Type': 'application/x-www-form-urlencoded'},
              body: body)
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
      if (success) {
        print('[ArcGIS] Customer added successfully, '
            'objectId=${addResults[0]['objectId']}');
      } else {
        print('[ArcGIS] addFeatures returned success=false: ${addResults[0]}');
      }
      return success;
    } catch (e) {
      print('[ArcGIS] addCustomerToLayer error: $e');
      return false;
    }
  }

  // ─── Socio-economic helper (unchanged) ───────────────────────────────────────

  /// Get socio-economic class for a building from the footprint layer.
  Future<String?> getSocioEconomicClass(String buildingId) async {
    try {
      final params = {
        'where': "building_id='${_escapeSql(buildingId)}'",
        'outFields': 'socio_economic_groups',
        'returnGeometry': 'false',
        'f': 'json',
      };

      final data = await _postQuery('$_footprintUrl/query', params);
      final features = data['features'] as List<dynamic>? ?? [];
      if (features.isEmpty) return null;

      final attrs = features[0]['attributes'] as Map<String, dynamic>;
      final socioClass = attrs['socio_economic_groups']?.toString();
      if (socioClass == null || socioClass.isEmpty) return null;

      final normalized = socioClass.toLowerCase().trim();
      return ['low', 'medium', 'high'].contains(normalized)
          ? normalized
          : null;
    } catch (e) {
      print('[ArcGIS] getSocioEconomicClass error: $e');
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
