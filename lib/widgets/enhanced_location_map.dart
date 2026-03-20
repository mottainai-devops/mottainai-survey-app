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

// ─── Isolate helper ───────────────────────────────────────────────────────────
// compute() only supports plain Dart types (primitives, List, Map).
// Custom class instances (LatLng, etc.) are NOT isolate-safe.
// The isolate returns only primitives; LatLng is constructed on the main thread.

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
        final lat = (coord[1] as num).toDouble();
        final lon = (coord[0] as num).toDouble();
        // Sanity check: valid WGS84 coordinates for Nigeria
        if (lat < 4.0 || lat > 14.0 || lon < 2.0 || lon > 15.0) continue;
        points.add([lat, lon]);
        sumLat += lat;
        sumLon += lon;
      }
      if (points.length < 3) continue;

      result.add({
        'buildingId': buildingId,
        'points': points,
        'centerLat': sumLat / points.length,
        'centerLon': sumLon / points.length,
      });
    } catch (_) {
      // Skip bad geometry silently
    }
  }
  return result;
}

// Lightweight structs — main thread only
class _PolygonRenderData {
  final String buildingId;
  final List<LatLng> points;
  final LatLng center;
  const _PolygonRenderData(
      {required this.buildingId, required this.points, required this.center});
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

  // flutter_map v7 hit notifier
  final LayerHitNotifier<String> _polygonHitNotifier = ValueNotifier(null);

  static const double _radiusKm = 1.0;
  // Labels appear at zoom 15.0+ (lower threshold so they're visible sooner)
  static const double _labelZoomThreshold = 15.0;
  static const int _maxVisiblePolygons = 80;

  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _mapReady = false;
  LatLng? _pendingCenter;

  _LoadPhase _phase = _LoadPhase.idle;
  String _statusText = '';
  String? _errorText;

  // All decoded polygon data (populated after compute())
  List<_PolygonRenderData> _allPolygonData = [];

  // Viewport-filtered render lists
  List<Polygon> _visiblePolygons = [];
  List<Marker> _visibleMarkers = [];

  // Customer names — fetched in parallel after initial render
  Map<String, String> _customerNames = {};

  // Raw polygon list (for tap lookup)
  List<BuildingPolygon> _cachedPolygons = [];
  BuildingPolygon? _selectedPolygon;
  String? _cacheInfo;

  // Camera state
  LatLngBounds? _currentBounds;
  double _currentZoom = 17.5;
  Timer? _cullingDebounce;

  @override
  void initState() {
    super.initState();
    _startPhase1_Locate();
  }

  @override
  void dispose() {
    _cullingDebounce?.cancel();
    _polygonHitNotifier.dispose();
    super.dispose();
  }

  // ─── PHASE 1: Get GPS location ───────────────────────────────────────────────

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
        _selectedLocation =
            (widget.initialLat != null && widget.initialLon != null)
                ? LatLng(widget.initialLat!, widget.initialLon!)
                : currentLoc;
        _pendingCenter = currentLoc;
      });

      if (widget.initialLat == null) {
        widget.onLocationSelected(
            locationData.latitude!, locationData.longitude!);
      }

      // Move map to user location
      if (_mapReady) {
        _mapController.move(currentLoc, 16.0);
      }

      await _startPhase2_LoadCache();
    } catch (e) {
      _setError('Failed to get location: $e');
    }
  }

  // ─── PHASE 2: Load from SQLite cache ────────────────────────────────────────

  Future<void> _startPhase2_LoadCache() async {
    if (_currentLocation == null || !mounted) return;

    setState(() {
      _phase = _LoadPhase.loadingCache;
      _statusText = 'Loading cached buildings...';
    });

    try {
      final cachedPolygons = await _polygonService.getCachedPolygonsNearLocation(
        lat: _currentLocation!.latitude,
        lon: _currentLocation!.longitude,
        radiusKm: _radiusKm,
      );

      final stats = await _polygonService.getCacheStats();

      if (!mounted) return;

      _cachedPolygons = cachedPolygons;

      setState(() {
        _cacheInfo =
            '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
      });

      if (cachedPolygons.isNotEmpty) {
        await _decodeAndRenderPolygons(cachedPolygons);
        unawaited(_fetchCustomerNamesParallel(cachedPolygons.take(50).toList()));
      }

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

  // ─── PHASE 3: Background sync from ArcGIS ───────────────────────────────────

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
        final freshPolygons =
            await _polygonService.getCachedPolygonsNearLocation(
          lat: curLat,
          lon: curLon,
          radiusKm: _radiusKm,
        );
        final stats = await _polygonService.getCacheStats();

        if (!mounted) return;
        _cachedPolygons = freshPolygons;
        setState(() {
          _cacheInfo =
              '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
        });

        await _decodeAndRenderPolygons(freshPolygons);
        unawaited(
            _fetchCustomerNamesParallel(freshPolygons.take(50).toList()));

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
      } else if (!result.success && _cachedPolygons.isEmpty) {
        if (mounted) {
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

    final inputMaps = polygons
        .map((p) => <String, dynamic>{
              'buildingId': p.buildingId,
              'geometry': p.geometry,
            })
        .toList();

    // Heavy JSON decoding runs in a background isolate
    final rawResults = await compute(_decodePolygonsInIsolate, inputMaps);

    if (!mounted) return;

    // Reconstruct LatLng on main thread (cheap)
    final polygonData = <_PolygonRenderData>[];
    for (final raw in rawResults) {
      final buildingId = raw['buildingId'] as String;
      final rawPoints = raw['points'] as List;
      final centerLat = raw['centerLat'] as double;
      final centerLon = raw['centerLon'] as double;

      final points = rawPoints
          .map((p) => LatLng((p as List)[0] as double, p[1] as double))
          .toList();

      polygonData.add(_PolygonRenderData(
        buildingId: buildingId,
        points: points,
        center: LatLng(centerLat, centerLon),
      ));
    }

    if (!mounted) return;
    setState(() {
      _allPolygonData = polygonData;
    });

    // Render immediately — do NOT wait for map to be ready.
    // Pass all polygons on first render; viewport culling kicks in after
    // the first camera move (onPositionChanged sets _currentBounds).
    _renderPolygons(useBoundsFilter: false);
  }

  // ─── Viewport culling ────────────────────────────────────────────────────────
  // Two modes:
  //   useBoundsFilter=false → render all polygons (up to cap), no bounds check.
  //     Used on first decode so polygons appear immediately regardless of map state.
  //   useBoundsFilter=true  → filter by current camera bounds.
  //     Used on camera moves after map is ready.

  void _renderPolygons({bool useBoundsFilter = true}) {
    if (!mounted || _allPolygonData.isEmpty) return;

    LatLngBounds? bounds;
    double zoom = _currentZoom;

    if (useBoundsFilter) {
      bounds = _currentBounds;
      // Try to get live bounds from controller if cached value is stale
      if (bounds == null && _mapReady) {
        try {
          bounds = _mapController.camera.visibleBounds;
          zoom = _mapController.camera.zoom;
        } catch (_) {
          // Camera not ready — fall through to no-filter mode
        }
      }
      // If we still have no bounds, fall back to rendering all
      if (bounds == null) useBoundsFilter = false;
    }

    final showLabels = zoom >= _labelZoomThreshold;
    final visiblePolygons = <Polygon>[];
    final visibleMarkers = <Marker>[];

    for (final pd in _allPolygonData) {
      if (visiblePolygons.length >= _maxVisiblePolygons) break;

      // Viewport culling with 20% padding to avoid pop-in at edges
      if (useBoundsFilter && bounds != null) {
        final padLat = (bounds.north - bounds.south) * 0.20;
        final padLon = (bounds.east - bounds.west) * 0.20;
        if (pd.center.latitude < bounds.south - padLat ||
            pd.center.latitude > bounds.north + padLat ||
            pd.center.longitude < bounds.west - padLon ||
            pd.center.longitude > bounds.east + padLon) {
          continue;
        }
      }

      final isSelected = _selectedPolygon?.buildingId == pd.buildingId;
      final isCaptured = _customerNames.containsKey(pd.buildingId);
      final polygonColor = _getPolygonColor(pd.buildingId);

      visiblePolygons.add(Polygon(
        points: pd.points,
        hitValue: pd.buildingId,
        // Polygon styling: thick border (4px) + semi-opaque fill (0.45)
        // so outlines are clearly visible against satellite imagery.
        color: isSelected
            ? Colors.blue.withValues(alpha: 0.55)
            : isCaptured
                ? Colors.green.withValues(alpha: 0.45)
                : polygonColor.withValues(alpha: 0.40),
        borderColor: isSelected
            ? Colors.blue
            : isCaptured
                ? Colors.green.shade700
                : polygonColor,
        borderStrokeWidth: isSelected ? 5.0 : 4.0,
      ));

      if (showLabels) {
        // Building ID label — non-interactive, shadow-backed
        visibleMarkers.add(Marker(
          point: pd.center,
          width: 90,
          height: 18,
          child: IgnorePointer(
            child: Text(
              pd.buildingId,
              style: TextStyle(
                color: isCaptured
                    ? Colors.green.shade900
                    : Colors.blue.shade900,
                fontSize: 7,
                fontWeight: FontWeight.bold,
                shadows: const [
                  Shadow(color: Colors.white, blurRadius: 4),
                  Shadow(
                      color: Colors.white,
                      blurRadius: 4,
                      offset: Offset(1, 1)),
                  Shadow(
                      color: Colors.white,
                      blurRadius: 4,
                      offset: Offset(-1, -1)),
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
            point: LatLng(pd.center.latitude + 0.00005, pd.center.longitude),
            width: 120,
            height: 22,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                final match = _cachedPolygons
                    .where((p) => p.buildingId == pd.buildingId)
                    .firstOrNull;
                if (match != null) _showExistingCustomersDialog(match);
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.shade700.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.white, width: 1),
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black26,
                        blurRadius: 2,
                        offset: Offset(0, 1)),
                  ],
                ),
                child: Text(
                  businessName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 7,
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
    }

    setState(() {
      _visiblePolygons = visiblePolygons;
      _visibleMarkers = visibleMarkers;
    });
  }

  // ─── Customer name fetching ───────────────────────────────────────────────────

  Future<void> _fetchCustomerNamesParallel(
      List<BuildingPolygon> polygons) async {
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
      _renderPolygons(useBoundsFilter: _currentBounds != null);
    }
  }

  // ─── Manual re-centre ────────────────────────────────────────────────────────

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
      _mapController.move(_currentLocation!, 17.5);

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

  // ─── Helpers ─────────────────────────────────────────────────────────────────

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _phase = _LoadPhase.error;
      _errorText = message;
    });
  }

  double _distanceMetres(
      double lat1, double lon1, double lat2, double lon2) {
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
    _renderPolygons(useBoundsFilter: _currentBounds != null);

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
            _currentLocation!.latitude,
            _currentLocation!.longitude,
          );
        },
      ),
    );
  }

  void _showExistingCustomersDialog(BuildingPolygon polygon) async {
    try {
      final result =
          await _apiService.getBuildingCustomers(polygon.buildingId);

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
                child:
                    const Icon(Icons.people, color: Colors.white, size: 24),
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
                    child: Icon(Icons.person,
                        color: Colors.green.shade700),
                  ),
                  title: Text(
                    customer['name'] ?? customer['label'] ?? 'Unknown',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold),
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
              child: const Text('ADD NEW',
                  style: TextStyle(color: Colors.white)),
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
          _StatusBanner(
              phase: _phase, text: _statusText, errorText: _errorText),

        // Cache info chip
        if (_cacheInfo != null)
          _CacheInfoChip(
            info: _cacheInfo!,
            overlayCount: _visiblePolygons.length,
            onRefresh: _getCurrentLocation,
          ),

        // Map — always rendered immediately
        Expanded(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLocation ??
                  LatLng(
                    widget.initialLat ?? 6.5244,
                    widget.initialLon ?? 3.3792,
                  ),
              initialZoom: 17.5,
              // MapOptions.onTap is ALWAYS invoked regardless of layers.
              // We check _polygonHitNotifier.value here to detect polygon taps.
              // If a polygon was hit, show the building info popup.
              // If no polygon was hit, treat as an empty-space tap (set pin).
              onTap: (tapPosition, latlng) {
                if (!mounted) return;
                final hitResult = _polygonHitNotifier.value;
                if (hitResult != null && hitResult.hitValues.isNotEmpty) {
                  // Polygon tap — show building info
                  final buildingId = hitResult.hitValues.first;
                  final match = _cachedPolygons
                      .where((p) => p.buildingId == buildingId)
                      .firstOrNull;
                  if (match != null) {
                    _showBuildingInfoPopup(match);
                    return;
                  }
                }
                // Empty-space tap — set location pin
                setState(() {
                  _selectedLocation = latlng;
                  _selectedPolygon = null;
                });
                widget.onLocationSelected(latlng.latitude, latlng.longitude);
              },
              onMapReady: () {
                _mapReady = true;
                // If location was obtained before map was ready, move now
                if (_pendingCenter != null) {
                  _mapController.move(_pendingCenter!, 16.0);
                  _pendingCenter = null;
                }
                // Re-render with bounds now that map is ready
                if (_allPolygonData.isNotEmpty) {
                  _renderPolygons(useBoundsFilter: false);
                }
              },
              onPositionChanged: (camera, hasGesture) {
                _currentBounds = camera.visibleBounds;
                _currentZoom = camera.zoom;
                // Debounce culling: 250ms after last camera move
                if (_allPolygonData.isNotEmpty) {
                  _cullingDebounce?.cancel();
                  _cullingDebounce = Timer(
                    const Duration(milliseconds: 250),
                    () => _renderPolygons(useBoundsFilter: true),
                  );
                }
              },
            ),
            children: [
              // Satellite tiles with OSM fallback
              TileLayer(
                urlTemplate:
                    'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                fallbackUrl:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.mottainai.mottainai_survey',
                panBuffer: 0,
              ),

              // Polygon layer with hit testing.
              // hitNotifier is populated by flutter_map's hit testing before
              // MapOptions.onTap fires. We read it in onTap above.
              PolygonLayer(
                polygons: _visiblePolygons,
                hitNotifier: _polygonHitNotifier,
              ),

              // Label markers (building IDs + business name badges).
              // Wrapped in TranslucentPointer so marker hit tests don't
              // block polygon hit tests on the layer below.
              TranslucentPointer(
                child: MarkerLayer(markers: _visibleMarkers),
              ),

              // Selected location pin — tip aligned to GPS coordinate.
              // TranslucentPointer: lets polygon hit tests pass through.
              if (_selectedLocation != null)
                TranslucentPointer(
                  child: MarkerLayer(
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
                ),

              // Current location dot — centred on GPS coordinate.
              // TranslucentPointer: lets polygon hit tests pass through.
              if (_currentLocation != null)
                TranslucentPointer(
                  child: MarkerLayer(
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
                            border:
                                Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                  color: Colors.black26, blurRadius: 4),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
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
          if (!isError) const SizedBox(width: 8),
          if (isError)
            Icon(Icons.error_outline,
                color: Colors.red.shade700, size: 16),
          if (isError) const SizedBox(width: 8),
          Expanded(
            child: Text(
              isError ? (errorText ?? 'An error occurred') : text,
              style: TextStyle(
                fontSize: 12,
                color: isError
                    ? Colors.red.shade700
                    : Colors.blue.shade700,
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

  const _CacheInfoChip({
    required this.info,
    required this.overlayCount,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.domain, color: Colors.green.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$info | overlays:$overlayCount',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: onRefresh,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
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

  const _MapControls({
    required this.onMyLocation,
    required this.isSyncing,
    required this.polygonCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            isSyncing
                ? 'Syncing...'
                : '$polygonCount buildings loaded',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
            ),
          ),
          ElevatedButton.icon(
            onPressed: onMyLocation,
            icon: const Icon(Icons.my_location, size: 18),
            label: const Text('My Location'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.domain,
                          color: Colors.green.shade700, size: 28),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            polygon.buildingId,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (polygon.address != null &&
                              polygon.address!.isNotEmpty)
                            Text(
                              polygon.address!,
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade600),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onSelect,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text(
                      'SELECT THIS BUILDING',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
