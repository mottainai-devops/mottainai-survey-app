import 'package:connectivity_plus/connectivity_plus.dart';
import '../database/database_helper.dart';
import '../models/building_polygon.dart';
import 'arcgis_service.dart';

class PolygonCacheService {
  final ArcGISService _arcgisService = ArcGISService();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// Sync polygons for current location (5km radius by default)
  Future<PolygonSyncResult> syncPolygonsForLocation({
    required double lat,
    required double lon,
    double radiusKm = 5.0,
    void Function(int fetched)? onProgress,
  }) async {
    try {
      // Check connectivity
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        return PolygonSyncResult(
          success: false,
          message: 'No internet connection',
          polygonCount: 0,
        );
      }

      // Fetch polygons from ArcGIS
      final polygons = await _arcgisService.fetchPolygonsNearLocation(
        lat: lat,
        lon: lon,
        radiusKm: radiusKm,
        onProgress: onProgress,
      );

      if (polygons.isEmpty) {
        return PolygonSyncResult(
          success: true,
          message: 'No polygons found in this area',
          polygonCount: 0,
        );
      }

      // Cache polygons in local database
      final polygonMaps = polygons.map((p) => p.toMap()).toList();
      await _dbHelper.cachePolygons(polygonMaps);

      return PolygonSyncResult(
        success: true,
        message: 'Successfully synced ${polygons.length} building polygons',
        polygonCount: polygons.length,
      );
    } catch (e) {
      return PolygonSyncResult(
        success: false,
        message: 'Sync failed: $e',
        polygonCount: 0,
      );
    }
  }

  /// Get cached polygons near location (offline-capable)
  Future<List<BuildingPolygon>> getCachedPolygonsNearLocation({
    required double lat,
    required double lon,
    double radiusKm = 5.0,
  }) async {
    try {
      final polygonMaps = await _dbHelper.getPolygonsNearLocation(
        lat: lat,
        lon: lon,
        radiusKm: radiusKm,
      );

      return polygonMaps
          .map((map) => BuildingPolygon.fromMap(map))
          .toList();
    } catch (e) {
      print('Error getting cached polygons: $e');
      return [];
    }
  }

  /// Get polygon by building ID (offline-capable)
  Future<BuildingPolygon?> getPolygonByBuildingId(String buildingId) async {
    try {
      final polygonMap = await _dbHelper.getPolygonByBuildingId(buildingId);
      if (polygonMap != null) {
        return BuildingPolygon.fromMap(polygonMap);
      }
      return null;
    } catch (e) {
      print('Error getting polygon by ID: $e');
      return null;
    }
  }

  /// Get cache statistics
  Future<CacheStats> getCacheStats() async {
    try {
      final count = await _dbHelper.getPolygonCacheCount();
      final lastUpdate = await _dbHelper.getLastPolygonCacheUpdate();
      
      return CacheStats(
        polygonCount: count,
        lastUpdated: lastUpdate,
      );
    } catch (e) {
      print('Error getting cache stats: $e');
      return CacheStats(
        polygonCount: 0,
        lastUpdated: null,
      );
    }
  }

  /// Clear all cached polygons
  Future<bool> clearCache() async {
    try {
      await _dbHelper.clearPolygonCache();
      return true;
    } catch (e) {
      print('Error clearing cache: $e');
      return false;
    }
  }

  /// Check if cache needs refresh (older than 7 days)
  Future<bool> needsRefresh() async {
    try {
      final lastUpdate = await _dbHelper.getLastPolygonCacheUpdate();
      if (lastUpdate == null) return true;
      
      final daysSinceUpdate = DateTime.now().difference(lastUpdate).inDays;
      return daysSinceUpdate > 7;
    } catch (e) {
      return true;
    }
  }
}

class PolygonSyncResult {
  final bool success;
  final String message;
  final int polygonCount;

  PolygonSyncResult({
    required this.success,
    required this.message,
    required this.polygonCount,
  });
}

class CacheStats {
  final int polygonCount;
  final DateTime? lastUpdated;

  CacheStats({
    required this.polygonCount,
    this.lastUpdated,
  });

  String get lastUpdatedText {
    if (lastUpdated == null) return 'Never';
    
    final now = DateTime.now();
    final difference = now.difference(lastUpdated!);
    
    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes} min ago';
    if (difference.inDays < 1) return '${difference.inHours} hours ago';
    if (difference.inDays < 7) return '${difference.inDays} days ago';
    
    return '${lastUpdated!.day}/${lastUpdated!.month}/${lastUpdated!.year}';
  }
}
