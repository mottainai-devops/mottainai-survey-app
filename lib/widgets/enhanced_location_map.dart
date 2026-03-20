import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/building_polygon.dart';
import '../services/polygon_cache_service.dart';
import '../services/api_service.dart';

// ─── Isolate helper: decode all polygon geometries off the UI thread ──────────
// compute() ONLY supports plain Dart types across isolate boundaries:
// primitives, List, Map, SendPort. Custom class instances (like LatLng or
// _PolygonRenderData) are NOT supported and cause a crash.
// Solution: the isolate returns List<Map<String,dynamic>> with only primitive
// values (doubles, strings, lists of doubles). LatLng objects are constructed
// on the main thread after compute() returns — that part is cheap.

// Input: list of {buildingId: String, geometry: String}
// Output: list of {
//   buildingId: String,
//   points: List<List<double>>,  // [[lat,lon], ...]
//   centerLat: double,
//   centerLon: double,
// }
List<Map<String, dynamic>> _decodePolygonsInIsolate(
    List<Map<String, dynamic>> input) {
  final result = <Map<String, dynamic>>[];

  for (final map in input) {
    try {
      final buildingId = map['buildingId'] as String? ?? '';
      final geometryStr = map['geometry'] as String? ?? '';
      if (geometryStr.isEmpty || buildingId.isEmpty) continue;

      final geometryJson = jsonDecode(geometryStr) as Map<String, dynamic>;
      final rings = geometryJson['rings'] as List?;
      if (rings == null || rings.isEmpty) continue;

      final ring = rings[0] as List;
      final points = <List<double>>[];
      double sumLat = 0, sumLon = 0;

      for (final coord in ring) {
        if (coord is! List || coord.length < 2) continue;
        final lat = coord[1] is int
            ? (coord[1] as int).toDouble()
            : (coord[1] as num).toDouble();
        final lon = coord[0] is int
            ? (coord[0] as int).toDouble()
            : (coord[0] as num).toDouble();
        points.add([lat, lon]);
        sumLat += lat;
        sumLon += lon;
      }
      if (points.length < 3) continue;

      result.add({
        'buildingId': buildingId,
        'points': points,          // List<List<double>> — isolate-safe
        'centerLat': sumLat / points.length,
        'centerLon': sumLon / points.length,
      });
    } catch (_) {
      // Skip bad geometry — never crash
    }
  }

  return result;
}

// Lightweight structs used only on the main thread (after compute returns)
class _PolygonRenderData {
  final String buildingId;
  final List<LatLng> points;
  const _PolygonRenderData({required this.buildingId, required this.points});
}

class _LabelData {
  final String buildingId;
  final LatLng center;
  const _LabelData({required this.buildingId, required this.center});
}

// ─── Main widget ──────────────────────────────────────────────────────────────

class EnhancedLocationMap extends StatefulWidget {
  final Function(double lat, double lon) onLocationSelected;
  final Function(BuildingPolygon)? onBuildingSelected;
  final double? initialLat;
  final double? initialLon;

  const EnhancedLocationMap({
    super.key,
    required this.onLocationSelected,
    this.onBuildingSelected,
    this.initialLat,
    this.initialLon,
  });

  @override
  State<EnhancedLocationMap> createState() => _EnhancedLocationMapState();
}

enum _LoadPhase { idle, locating, loadingCache, syncing, ready, error }

class _EnhancedLocationMapState extends State<EnhancedLocationMap> {
  final MapController _mapController = MapController();
  final PolygonCacheService _polygonService = PolygonCacheService();
  final ApiService _apiService = ApiService();

  // flutter_map v7 hit notifier — read synchronously inside GestureDetector.onTap
  final LayerHitNotifier<String> _polygonHitNotifier = ValueNotifier(null);

  static const double _radiusKm = 1.0;

  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _mapReady = false;
  LatLng? _pendingCenter;

  _LoadPhase _phase = _LoadPhase.idle;
  String _statusText = '';
  String? _errorText;

  // Full decoded geometry — computed in isolate, never on UI thread
  List<_PolygonRenderData> _allPolygonData = [];
  List<_LabelData> _allLabelData = [];

  // Viewport-filtered render lists — updated on camera move
  List<Polygon> _visiblePolygons = [];
  List<Marker> _visibleMarkers = [];

  // Customer names — fetched in parallel after initial render
  Map<String, String> _customerNames = {};

  // Raw polygon list (for tap lookup)
  List<BuildingPolygon> _cachedPolygons = [];
  BuildingPolygon? _selectedPolygon;
  String? _cacheInfo;

  // Camera bounds for viewport culling
  LatLngBounds? _currentBounds;

  @override
  void initState() {
    super.initState();
    _startPhase1_Locate();
  }

  @override
  void dispose() {
    _polygonHitNotifier.dispose();
    super.dispose();
  }

  // ─── PHASE 1: Get GPS location (show map immediately, locate in background) ─

  Future<void> _startPhase1_Locate() async {
    if (!mounted) return;
    setState(() {
      _phase = _LoadPhase.locating;
      _statusText = 'Getting your location...';
    });

    try {
      final location = loc.Location();

      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) {
          _setError('Location services are disabled. Please enable them.');
          return;
        }
      }

      loc.PermissionStatus permission = await location.hasPermission();
      if (permission == loc.PermissionStatus.denied) {
        permission = await location.requestPermission();
        if (permission != loc.PermissionStatus.granted) {
          _setError('Location permission denied.');
          return;
        }
      }

      final locationData = await location.getLocation();
      if (!mounted) return;

      final currentLoc =
          LatLng(locationData.latitude!, locationData.longitude!);

      setState(() {
        _currentLocation = currentLoc;
        _selectedLocation = (widget.initialLat != null && widget.initialLon != null)
            ? LatLng(widget.initialLat!, widget.initialLon!)
            : currentLoc;
        _pendingCenter = currentLoc;
      });

      if (widget.initialLat == null) {
        widget.onLocationSelected(
            locationData.latitude!, locationData.longitude!);
      }

      if (_mapReady) {
        _mapController.move(currentLoc, 16.0);
      }

      // Phase 2 starts immediately after location is known
      _startPhase2_LoadCache();
    } catch (e) {
      _setError('Failed to get location: $e');
    }
  }

  // ─── PHASE 2: Load from local SQLite cache (fast, offline-capable) ──────────

  Future<void> _startPhase2_LoadCache() async {
    if (_currentLocation == null || !mounted) return;

    setState(() {
      _phase = _LoadPhase.loadingCache;
      _statusText = 'Loading cached buildings...';
    });

    try {
      final cachedMaps = await _polygonService.getCachedPolygonsNearLocation(
        lat: _currentLocation!.latitude,
        lon: _currentLocation!.longitude,
        radiusKm: _radiusKm,
      );

      final stats = await _polygonService.getCacheStats();

      if (!mounted) return;

      _cachedPolygons = cachedMaps;

      setState(() {
        _cacheInfo =
            '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
      });

      if (cachedMaps.isNotEmpty) {
        // Decode geometries in isolate — never block UI thread
        await _decodeAndRenderPolygons(cachedMaps);
        // Fetch customer names in parallel — non-blocking, updates labels later
        unawaited(_fetchCustomerNamesParallel(cachedMaps.take(50).toList()));
      }

      // Phase 3: background sync (always runs, even if cache has data)
      unawaited(_startPhase3_BackgroundSync());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _LoadPhase.ready;
        _statusText = 'Cache load failed — syncing from server...';
      });
      unawaited(_startPhase3_BackgroundSync());
    }
  }

  // ─── PHASE 3: Background sync from ArcGIS (never blocks UI) ─────────────────

  Future<void> _startPhase3_BackgroundSync() async {
    if (_currentLocation == null || !mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final lastSyncLat = prefs.getDouble('last_sync_lat');
    final lastSyncLon = prefs.getDouble('last_sync_lon');
    final curLat = _currentLocation!.latitude;
    final curLon = _currentLocation!.longitude;

    final movedFarEnough = lastSyncLat == null ||
        lastSyncLon == null ||
        _distanceMetres(curLat, curLon, lastSyncLat, lastSyncLon) > 300;

    final needsRefresh = await _polygonService.needsRefresh();

    if (!movedFarEnough && !needsRefresh && _cachedPolygons.isNotEmpty) {
      // Cache is fresh and we haven't moved — skip sync
      if (!mounted) return;
      setState(() {
        _phase = _LoadPhase.ready;
        _statusText = '';
      });
      return;
    }

    if (!mounted) return;
    setState(() {
      _phase = _LoadPhase.syncing;
      _statusText = 'Syncing buildings...';
    });

    try {
      final result = await _polygonService.syncPolygonsForLocation(
        lat: curLat,
        lon: curLon,
        radiusKm: _radiusKm,
        onProgress: (fetched) {
          if (mounted) {
            setState(() {
              _statusText = 'Syncing buildings... ($fetched fetched)';
            });
          }
        },
      );

      if (!mounted) return;

      if (result.success && result.polygonCount > 0) {
        final freshMaps = await _polygonService.getCachedPolygonsNearLocation(
          lat: curLat,
          lon: curLon,
          radiusKm: _radiusKm,
        );
        final stats = await _polygonService.getCacheStats();

        if (!mounted) return;
        _cachedPolygons = freshMaps;
        setState(() {
          _cacheInfo =
              '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
        });

        await _decodeAndRenderPolygons(freshMaps);
        unawaited(_fetchCustomerNamesParallel(freshMaps.take(50).toList()));

        await prefs.setDouble('last_sync_lat', curLat);
        await prefs.setDouble('last_sync_lon', curLon);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.message),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (!result.success) {
        if (mounted && _cachedPolygons.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.message),
              backgroundColor: Colors.orange,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync error: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _phase = _LoadPhase.ready;
          _statusText = '';
        });
      }
    }
  }

  // ─── Geometry decoding in isolate ────────────────────────────────────────────

  Future<void> _decodeAndRenderPolygons(List<BuildingPolygon> polygons) async {
    if (!mounted) return;

    // Serialize to plain List<Map> — ONLY primitives cross isolate boundaries.
    // compute() uses SendPort.send() which does NOT support custom class instances.
    final inputMaps = polygons
        .map((p) => <String, dynamic>{
              'buildingId': p.buildingId,
              'geometry': p.geometry,
            })
        .toList();

    // Run JSON decoding in a separate Dart isolate — never on UI thread.
    // Returns List<Map<String,dynamic>> with only primitive values.
    final rawResults = await compute(
      _decodePolygonsInIsolate,
      inputMaps,
    );

    if (!mounted) return;

    // Reconstruct LatLng objects on the main thread — this is cheap.
    final polygonData = <_PolygonRenderData>[];
    final labelData = <_LabelData>[];

    for (final raw in rawResults) {
      final buildingId = raw['buildingId'] as String;
      final rawPoints = raw['points'] as List;
      final centerLat = raw['centerLat'] as double;
      final centerLon = raw['centerLon'] as double;

      final points = rawPoints
          .map((p) => LatLng((p as List)[0] as double, p[1] as double))
          .toList();

      polygonData.add(_PolygonRenderData(buildingId: buildingId, points: points));
      labelData.add(_LabelData(
        buildingId: buildingId,
        center: LatLng(centerLat, centerLon),
      ));
    }

    setState(() {
      _allPolygonData = polygonData;
      _allLabelData = labelData;
    });

    _updateVisiblePolygons();
  }

  // ─── Viewport culling — only render polygons in current map bounds ────────────

  void _updateVisiblePolygons() {
    if (!mounted) return;

    final bounds = _currentBounds;

    final visiblePolygons = <Polygon>[];
    final visibleMarkers = <Marker>[];

    for (int i = 0; i < _allPolygonData.length; i++) {
      final pd = _allPolygonData[i];
      final ld = _allLabelData[i];

      // If bounds are known, cull polygons outside viewport (with 20% padding)
      if (bounds != null) {
        final padLat = (bounds.north - bounds.south) * 0.2;
        final padLon = (bounds.east - bounds.west) * 0.2;
        if (ld.center.latitude < bounds.south - padLat ||
            ld.center.latitude > bounds.north + padLat ||
            ld.center.longitude < bounds.west - padLon ||
            ld.center.longitude > bounds.east + padLon) {
          continue;
        }
      }

      final isSelected = _selectedPolygon?.buildingId == pd.buildingId;
      final isCaptured = _customerNames.containsKey(pd.buildingId);
      final polygonColor = _getPolygonColor(pd.buildingId);

      visiblePolygons.add(Polygon(
        points: pd.points,
        hitValue: pd.buildingId,
        color: isSelected
            ? Colors.blue.withValues(alpha: 0.5)
            : isCaptured
                ? Colors.green.withValues(alpha: 0.35)
                : polygonColor.withValues(alpha: 0.25),
        borderColor: isSelected
            ? Colors.blue
            : isCaptured
                ? Colors.green.shade700
                : polygonColor,
        borderStrokeWidth: isSelected ? 5.0 : 2.5,
      ));

      // Building ID label
      visibleMarkers.add(Marker(
        point: ld.center,
        width: 100,
        height: 20,
        child: IgnorePointer(
          child: Text(
            pd.buildingId,
            style: TextStyle(
              color: isCaptured ? Colors.green.shade900 : Colors.blue.shade900,
              fontSize: 7,
              fontWeight: FontWeight.bold,
              shadows: const [
                Shadow(color: Colors.white, blurRadius: 4),
                Shadow(color: Colors.white, blurRadius: 4, offset: Offset(1, 1)),
                Shadow(color: Colors.white, blurRadius: 4, offset: Offset(-1, -1)),
              ],
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
      ));

      // Business name badge — only for captured buildings
      if (isCaptured) {
        final businessName = _customerNames[pd.buildingId]!;
        visibleMarkers.add(Marker(
          point: LatLng(ld.center.latitude + 0.00005, ld.center.longitude),
          width: 130,
          height: 24,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              final match = _cachedPolygons
                  .where((p) => p.buildingId == pd.buildingId)
                  .firstOrNull;
              if (match != null) _showExistingCustomersDialog(match);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade700.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white, width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 3,
                    offset: Offset(0, 1),
                  ),
                ],
              ),
              child: Text(
                businessName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ),
        ));
      }
    }

    setState(() {
      _visiblePolygons = visiblePolygons;
      _visibleMarkers = visibleMarkers;
    });
  }

  // ─── Parallel customer name fetching ─────────────────────────────────────────
  // Runs all API calls concurrently (not serially) with a per-call timeout.
  // Decoupled from initial render — polygons show immediately, names appear later.

  Future<void> _fetchCustomerNamesParallel(List<BuildingPolygon> polygons) async {
    const callTimeout = Duration(seconds: 5);

    final futures = polygons.map((polygon) async {
      try {
        final result = await _apiService
            .getBuildingCustomers(polygon.buildingId)
            .timeout(callTimeout);
        if (result['success'] == true && result['existingCustomers'] != null) {
          final customers = result['existingCustomers'] as List;
          if (customers.isNotEmpty) {
            final name = (customers[0]['name'] as String?) ??
                (customers[0]['label'] as String? ?? polygon.buildingId);
            return MapEntry(polygon.buildingId, name);
          }
        }
      } catch (_) {
        // Non-fatal — skip label for this building
      }
      return null;
    });

    final results = await Future.wait(futures);

    if (!mounted) return;

    final newNames = <String, String>{};
    for (final entry in results) {
      if (entry != null) newNames[entry.key] = entry.value;
    }

    if (newNames.isNotEmpty) {
      setState(() {
        _customerNames = {..._customerNames, ...newNames};
      });
      _updateVisiblePolygons();
    }
  }

  // ─── Manual re-sync (Download button) ────────────────────────────────────────

  Future<void> _getCurrentLocation() async {
    try {
      final location = loc.Location();
      final locationData = await location.getLocation();

      if (!mounted) return;
      setState(() {
        _currentLocation =
            LatLng(locationData.latitude!, locationData.longitude!);
        _selectedLocation = _currentLocation;
      });

      widget.onLocationSelected(
          locationData.latitude!, locationData.longitude!);
      _mapController.move(_currentLocation!, 18.5);

      await _startPhase2_LoadCache();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to get location: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ─── Polygon tap handler (flutter_map v7 pattern) ────────────────────────────

  void _handlePolygonTap() {
    final hitResult = _polygonHitNotifier.value;
    if (hitResult == null || hitResult.hitValues.isEmpty) return;

    final buildingId = hitResult.hitValues.first;
    final match =
        _cachedPolygons.where((p) => p.buildingId == buildingId).firstOrNull;
    if (match == null) return;

    _showBuildingInfoPopup(match);
  }

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    final hitResult = _polygonHitNotifier.value;
    if (hitResult != null && hitResult.hitValues.isNotEmpty) return;

    if (!mounted) return;
    setState(() {
      _selectedLocation = position;
      _selectedPolygon = null;
    });
    widget.onLocationSelected(position.latitude, position.longitude);
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _LoadPhase.error;
      _errorText = message;
    });
  }

  double _distanceMetres(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  Color _getPolygonColor(String buildingId) {
    const colors = [
      Color(0xFFE91E63), Color(0xFF9C27B0), Color(0xFF3F51B5),
      Color(0xFF2196F3), Color(0xFF009688), Color(0xFF4CAF50),
      Color(0xFFFFC107), Color(0xFFFF9800), Color(0xFFFF5722),
      Color(0xFFF44336),
    ];
    return colors[buildingId.hashCode.abs() % colors.length];
  }

  // ─── Dialogs ─────────────────────────────────────────────────────────────────

  void _showBuildingInfoPopup(BuildingPolygon polygon) {
    if (!mounted) return;
    setState(() {
      _selectedPolygon = polygon;
    });
    _updateVisiblePolygons();

    if (widget.onBuildingSelected != null) {
      widget.onBuildingSelected!(polygon);
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _BuildingInfoSheet(
        polygon: polygon,
        onSelect: () {
          Navigator.pop(context);
          widget.onLocationSelected(
            double.tryParse(polygon.address?.split(',').first ?? '') ??
                _currentLocation!.latitude,
            _currentLocation!.longitude,
          );
        },
      ),
    );
  }

  void _showExistingCustomersDialog(BuildingPolygon polygon) async {
    try {
      final result = await _apiService.getBuildingCustomers(polygon.buildingId);

      if (result['success'] != true || result['existingCustomers'] == null) {
        _showBuildingInfoPopup(polygon);
        return;
      }

      final existingCustomers = result['existingCustomers'] as List;
      if (existingCustomers.isEmpty) {
        _showBuildingInfoPopup(polygon);
        return;
      }

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.green.shade700,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.people, color: Colors.white, size: 24),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'EXISTING CUSTOMERS',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: existingCustomers.length,
              itemBuilder: (context, index) {
                final customer = existingCustomers[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.green.shade100,
                    child: Icon(Icons.person, color: Colors.green.shade700),
                  ),
                  title: Text(
                    customer['name'] ?? customer['label'] ?? 'Unknown',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(customer['phone'] ?? ''),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CLOSE'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _showBuildingInfoPopup(polygon);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
              ),
              child: const Text('ADD NEW', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    } catch (e) {
      _showBuildingInfoPopup(polygon);
    }
  }

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Status banner
        if (_phase != _LoadPhase.ready && _phase != _LoadPhase.idle)
          _StatusBanner(phase: _phase, text: _statusText, errorText: _errorText),

        // Cache info chip
        if (_cacheInfo != null)
          _CacheInfoChip(
            info: _cacheInfo!,
            overlayCount: _visiblePolygons.length,
            onRefresh: _getCurrentLocation,
          ),

        // Map — always rendered, never blocked
        Expanded(
          child: GestureDetector(
            // CRITICAL: read hitNotifier.value synchronously here, in the same
            // call frame as the tap. flutter_map v7 clears the notifier after
            // the tap propagates, so reading it in a separate method returns null.
            onTap: () {
              final hitResult = _polygonHitNotifier.value;
              if (hitResult != null && hitResult.hitValues.isNotEmpty) {
                final buildingId = hitResult.hitValues.first;
                final match = _cachedPolygons
                    .where((p) => p.buildingId == buildingId)
                    .firstOrNull;
                if (match != null) _showBuildingInfoPopup(match);
              }
            },
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentLocation ??
                    LatLng(
                      widget.initialLat ?? 6.5244,
                      widget.initialLon ?? 3.3792,
                    ),
                initialZoom: 16.0,
                onTap: _onMapTap,
                onMapReady: () {
                  _mapReady = true;
                  if (_pendingCenter != null) {
                    _mapController.move(_pendingCenter!, 16.0);
                    _pendingCenter = null;
                  }
                },
                onPositionChanged: (camera, hasGesture) {
                  // Update viewport bounds for culling
                  _currentBounds = camera.visibleBounds;
                  // Debounce: only re-render if polygons are loaded
                  if (_allPolygonData.isNotEmpty) {
                    _updateVisiblePolygons();
                  }
                },
              ),
              children: [
                // Satellite tile layer with OSM fallback
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                  fallbackUrl:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.mottainai.mottainai_survey',
                  panBuffer: 0,
                ),

                // Polygon layer with hit testing
                PolygonLayer(
                  polygons: _visiblePolygons,
                  hitNotifier: _polygonHitNotifier,
                ),

                // Label markers
                MarkerLayer(markers: _visibleMarkers),

                // Selected location pin — alignment: bottomCenter so the
                // tip of the pin icon aligns exactly with the GPS coordinate.
                if (_selectedLocation != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _selectedLocation!,
                        width: 40,
                        height: 48,
                        alignment: Alignment.bottomCenter,
                        child: const Icon(
                          Icons.location_pin,
                          color: Colors.red,
                          size: 40,
                        ),
                      ),
                    ],
                  ),

                // Current location dot — centred exactly on GPS coordinate
                if (_currentLocation != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _currentLocation!,
                        width: 20,
                        height: 20,
                        alignment: Alignment.center,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.blue,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),

        // Bottom controls
        _MapControls(
          onMyLocation: _getCurrentLocation,
          isSyncing: _phase == _LoadPhase.syncing,
          polygonCount: _cachedPolygons.length,
        ),
      ],
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final _LoadPhase phase;
  final String text;
  final String? errorText;

  const _StatusBanner(
      {required this.phase, required this.text, this.errorText});

  @override
  Widget build(BuildContext context) {
    final isError = phase == _LoadPhase.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: isError ? Colors.red.shade50 : Colors.blue.shade50,
      child: Row(
        children: [
          if (!isError)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (isError)
            Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              isError ? (errorText ?? 'An error occurred') : text,
              style: TextStyle(
                fontSize: 12,
                color: isError ? Colors.red.shade700 : Colors.blue.shade800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CacheInfoChip extends StatelessWidget {
  final String info;
  final int overlayCount;
  final VoidCallback onRefresh;

  const _CacheInfoChip(
      {required this.info,
      required this.overlayCount,
      required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.domain, color: Colors.green.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$info | overlays:$overlayCount',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          GestureDetector(
            onTap: onRefresh,
            child: Icon(Icons.refresh, size: 18, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}

class _MapControls extends StatelessWidget {
  final VoidCallback onMyLocation;
  final bool isSyncing;
  final int polygonCount;

  const _MapControls(
      {required this.onMyLocation,
      required this.isSyncing,
      required this.polygonCount});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, -2)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              polygonCount > 0
                  ? '$polygonCount buildings loaded'
                  : 'No buildings loaded',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          ElevatedButton.icon(
            onPressed: isSyncing ? null : onMyLocation,
            icon: isSyncing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.my_location, size: 16),
            label: Text(isSyncing ? 'Syncing...' : 'My Location'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Building info bottom sheet ───────────────────────────────────────────────

class _BuildingInfoSheet extends StatelessWidget {
  final BuildingPolygon polygon;
  final VoidCallback onSelect;

  const _BuildingInfoSheet({required this.polygon, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Building ${polygon.buildingId}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (polygon.address != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.location_on, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    polygon.address!,
                    style: TextStyle(color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
          ],
          if (polygon.zone != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.map, size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 4),
                Text('Zone: ${polygon.zone}',
                    style: TextStyle(color: Colors.grey.shade700)),
              ],
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onSelect,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: const Text('SELECT THIS BUILDING',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
