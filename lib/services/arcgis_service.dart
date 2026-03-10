import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/building_polygon.dart';

class ArcGISService {
  // Building footprints from Customer Registration Map (Item ID: 8a269d4d8044457c8e0c646562dff53d)
  // This is the New_Footprints_gdb layer within the Customer_RegMap web map
  static const String _baseUrl =
      'https://services3.arcgis.com/VYBpf26AGQNwssLH/arcgis/rest/services/New_Footprints_gdb_b1422/FeatureServer/0';

  // The service has 1.5M features total. Use small pages to avoid connection abort on mobile.
  // Reduced from 100 to 50 to make each request smaller and faster on slow mobile connections.
  static const int _pageSize = 50;

  // Request timeout - mobile connections can be slow.
  // Increased from 30s to 90s because ArcGIS can be slow on 4G networks.
  static const Duration _timeout = Duration(seconds: 90);

  // Number of retries per page on timeout
  static const int _maxRetries = 2;

  /// Fetch building polygons within radius from a center point.
  ///
  /// [lat] and [lon] are the center coordinates (WGS84).
  /// [radiusKm] is the search radius in kilometers.
  ///   Default is 1.0km — the dataset has 1.5M features so a large
  ///   radius returns thousands of polygons and causes connection aborts on
  ///   mobile networks. Increase only when on a fast connection.
  ///
  /// [onProgress] optional callback called after each page with the running total.
  ///
  /// Fetches results in pages of [_pageSize] to avoid oversized responses.
  Future<List<BuildingPolygon>> fetchPolygonsNearLocation({
    required double lat,
    required double lon,
    double radiusKm = 1.0,
    void Function(int fetched)? onProgress,
  }) async {
    final radiusMeters = (radiusKm * 1000).round();
    final geometryJson =
        '{"x":$lon,"y":$lat,"spatialReference":{"wkid":4326}}';

    final List<BuildingPolygon> allPolygons = [];
    int offset = 0;
    bool hasMore = true;

    print('[ArcGIS] Fetching polygons within ${radiusMeters}m of ($lat, $lon)');

    while (hasMore) {
      try {
        final queryParams = {
          'where': '1=1',
          'geometry': geometryJson,
          'geometryType': 'esriGeometryPoint',
          'inSR': '4326', // Required: tells ArcGIS the input CRS is WGS84
          'spatialRel': 'esriSpatialRelIntersects',
          'distance': radiusMeters.toString(),
          'units': 'esriSRUnit_Meter',
          'outFields':
              'building_id,business_name,cust_phone,customer_email,address,Zone,socio_economic_groups',
          'returnGeometry': 'true',
          'outSR': '4326', // Return coordinates in WGS84 (lon, lat) - avoids local projection issues
          'resultRecordCount': _pageSize.toString(),
          'resultOffset': offset.toString(),
          'f': 'json',
          // Service is public - no token required
        };

        final uri =
            Uri.parse('$_baseUrl/query').replace(queryParameters: queryParams);

        print(
            '[ArcGIS] Fetching page offset=$offset, pageSize=$_pageSize ...');

        http.Response? response;
        int attempt = 0;
        while (attempt < _maxRetries) {
          try {
            response = await http.get(uri).timeout(_timeout);
            break; // success
          } catch (retryErr) {
            attempt++;
            print('[ArcGIS] Attempt $attempt failed: $retryErr');
            if (attempt >= _maxRetries) rethrow;
            print('[ArcGIS] Retrying in 3 seconds...');
            await Future.delayed(const Duration(seconds: 3));
          }
        }

        if (response!.statusCode != 200) {
          throw Exception(
              'ArcGIS HTTP ${response.statusCode}: ${response.body.substring(0, 200)}');
        }

        final data = jsonDecode(response.body);

        if (data['error'] != null) {
          throw Exception(
              'ArcGIS API Error: ${data['error']['message']} (code ${data['error']['code']})');
        }

        final features = data['features'] as List<dynamic>? ?? [];
        final exceeded = data['exceededTransferLimit'] as bool? ?? false;

        final page = features
            .map((f) =>
                BuildingPolygon.fromArcGIS(f as Map<String, dynamic>))
            .toList();

        allPolygons.addAll(page);
        print('[ArcGIS] Page fetched: ${page.length} features (total so far: ${allPolygons.length})');
        onProgress?.call(allPolygons.length);

        // Continue paginating only if the server says there are more records
        if (exceeded && features.length == _pageSize) {
          offset += _pageSize;
        } else {
          hasMore = false;
        }

        // Safety cap: stop after 1000 buildings to avoid memory issues
        if (allPolygons.length >= 1000) {
          print('[ArcGIS] Reached 1000-building safety cap, stopping pagination');
          hasMore = false;
        }
      } catch (e) {
        print('[ArcGIS] Error fetching page at offset $offset: $e');
        // Return whatever we have so far rather than losing everything
        hasMore = false;
        if (allPolygons.isEmpty) {
          rethrow;
        }
      }
    }

    print('[ArcGIS] Done: ${allPolygons.length} buildings fetched');
    return allPolygons;
  }

  /// Fetch a single building polygon by building ID
  Future<BuildingPolygon?> fetchPolygonByBuildingId(String buildingId) async {
    try {
      final queryParams = {
        'where': "building_id='$buildingId'",
        'outFields':
            'building_id,business_name,cust_phone,customer_email,address,Zone,socio_economic_groups',
        'returnGeometry': 'true',
        'outSR': '4326', // Return coordinates in WGS84 (lon, lat)
        'f': 'json',
        // Service is public - no token required
      };

      final uri =
          Uri.parse('$_baseUrl/query').replace(queryParameters: queryParams);

      final response = await http.get(uri).timeout(_timeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['error'] != null) {
          throw Exception(
              'ArcGIS API Error: ${data['error']['message']}');
        }

        final features = data['features'] as List<dynamic>? ?? [];

        if (features.isEmpty) {
          return null;
        }

        return BuildingPolygon.fromArcGIS(
            features[0] as Map<String, dynamic>);
      } else {
        throw Exception(
            'Failed to fetch polygon: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching polygon by ID: $e');
      return null;
    }
  }

  /// Test connection to ArcGIS service
  Future<bool> testConnection() async {
    try {
      // Service is public - no token required
      final uri = Uri.parse('$_baseUrl?f=json');
      final response = await http.get(uri).timeout(_timeout);
      return response.statusCode == 200;
    } catch (e) {
      print('ArcGIS connection test failed: $e');
      return false;
    }
  }

  /// Get socio-economic class for a building from the feature layer
  /// Returns: "low", "medium", "high", or null if not found
  Future<String?> getSocioEconomicClass(String buildingId) async {
    try {
      final queryParams = {
        'where': "building_id='$buildingId'",
        'outFields': 'socio_economic_groups',
        'returnGeometry': 'false',
        'f': 'json',
        // Service is public - no token required
      };

      final uri =
          Uri.parse('$_baseUrl/query').replace(queryParameters: queryParams);

      print('[ArcGIS] Querying socio-class for building: $buildingId');
      final response = await http.get(uri).timeout(_timeout);

      if (response.statusCode != 200) {
        print('[ArcGIS] Query failed with status: ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body);

      if (data['error'] != null) {
        print('[ArcGIS] API Error: ${data['error']['message']}');
        return null;
      }

      final features = data['features'] as List<dynamic>? ?? [];

      if (features.isEmpty) {
        print('[ArcGIS] No features found for buildingId: $buildingId');
        return null;
      }

      // Extract socio-economic class from first feature
      final attributes =
          features[0]['attributes'] as Map<String, dynamic>;
      final socioClass = attributes['socio_economic_groups'] as String?;

      // Validate and normalize the value
      if (socioClass == null || socioClass.isEmpty) {
        print('[ArcGIS] No socio-class value for building: $buildingId');
        return null;
      }

      final normalized = socioClass.toLowerCase().trim();
      if (!['low', 'medium', 'high'].contains(normalized)) {
        print('[ArcGIS] Invalid socio-class value: $socioClass');
        return null;
      }

      print(
          '[ArcGIS] Socio-class found: $normalized for building: $buildingId');
      return normalized;
    } catch (e) {
      print('[ArcGIS] Error querying socio-class: $e');
      return null;
    }
  }
}
