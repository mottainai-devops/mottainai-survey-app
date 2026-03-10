import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/building_polygon.dart';

class ArcGISService {
  // Building footprints from Customer Registration Map (Item ID: 8a269d4d8044457c8e0c646562dff53d)
  // This is the New_Footprints_gdb layer within the Customer_RegMap web map
  static const String _baseUrl =
      'https://services3.arcgis.com/VYBpf26AGQNwssLH/arcgis/rest/services/New_Footprints_gdb_b1422/FeatureServer/0';
  
  static const String _apiKey =
      'AAPTxy8BH1VEsoebNVZXo8HurDkT4HeplNOm_pLCsV2-wHXD7esJFqWCGo3oDxTaOVO68fIzhjQ4gSKqccl-uynuHunhlN5t3E_x5N010mOKYQRyFm3vYXqvila3dJ3Ax81DMK2WyxFt6mqhwzxdkdhmm7USv7-cQi07L_22-MTRC95Rns1BHueP3kR_yXyAyh1WEFAm9Q7KFELPkRpT_5cjWvbDo2rWZhtHOb5xFr_7bOA.AT1_n5wNkDcc';

  /// Fetch building polygons within radius from a center point
  /// [lat] and [lon] are the center coordinates
  /// [radiusKm] is the search radius in kilometers (default 5km)
  Future<List<BuildingPolygon>> fetchPolygonsNearLocation({
    required double lat,
    required double lon,
    double radiusKm = 5.0,
  }) async {
    try {
      // Convert radius to meters for ArcGIS query
      final radiusMeters = radiusKm * 1000;
      
      // Build query URL with spatial filter
      // NOTE: inSR=4326 is required to tell ArcGIS the input geometry is in WGS84
      // Without it, ArcGIS returns "Invalid query parameters" error
      final queryParams = {
        'where': '1=1', // Get all features within geometry
        'geometry': '{"x":$lon,"y":$lat,"spatialReference":{"wkid":4326}}',
        'geometryType': 'esriGeometryPoint',
        'inSR': '4326', // Required: input spatial reference (WGS84)
        'spatialRel': 'esriSpatialRelIntersects',
        'distance': radiusMeters.toString(),
        'units': 'esriSRUnit_Meter',
        'outFields': 'building_id,business_name,cust_phone,customer_email,address,Zone,socio_economic_groups',
        'returnGeometry': 'true',
        'f': 'json',
        // Service is public - no token required
      };

      final uri = Uri.parse('$_baseUrl/query').replace(queryParameters: queryParams);
      
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data['error'] != null) {
          throw Exception('ArcGIS API Error: ${data['error']['message']}');
        }

        final features = data['features'] as List<dynamic>? ?? [];
        
        return features
            .map((feature) => BuildingPolygon.fromArcGIS(feature as Map<String, dynamic>))
            .toList();
      } else {
        throw Exception('Failed to fetch polygons: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching ArcGIS polygons: $e');
      rethrow;
    }
  }

  /// Fetch a single building polygon by building ID
  Future<BuildingPolygon?> fetchPolygonByBuildingId(String buildingId) async {
    try {
      final queryParams = {
        'where': "building_id='$buildingId'",
        'outFields': 'building_id,business_name,cust_phone,customer_email,address,Zone,socio_economic_groups',
        'returnGeometry': 'true',
        'f': 'json',
        // Service is public - no token required
      };

      final uri = Uri.parse('$_baseUrl/query').replace(queryParameters: queryParams);
      
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        
        if (data['error'] != null) {
          throw Exception('ArcGIS API Error: ${data['error']['message']}');
        }

        final features = data['features'] as List<dynamic>? ?? [];
        
        if (features.isEmpty) {
          return null;
        }

        return BuildingPolygon.fromArcGIS(features[0] as Map<String, dynamic>);
      } else {
        throw Exception('Failed to fetch polygon: ${response.statusCode}');
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
      final response = await http.get(uri);
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

      final uri = Uri.parse('$_baseUrl/query').replace(queryParameters: queryParams);
      
      print('[ArcGIS] Querying socio-class for building: $buildingId');
      final response = await http.get(uri).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          throw Exception('ArcGIS query timeout');
        },
      );

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
      final attributes = features[0]['attributes'] as Map<String, dynamic>;
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

      print('[ArcGIS] Socio-class found: $normalized for building: $buildingId');
      return normalized;
    } catch (e) {
      print('[ArcGIS] Error querying socio-class: $e');
      return null;
    }
  }
}
