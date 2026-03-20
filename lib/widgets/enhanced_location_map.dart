import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/building_polygon.dart';
import '../services/polygon_cache_service.dart';
import '../services/api_service.dart';

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

class _EnhancedLocationMapState extends State<EnhancedLocationMap> {
  final MapController _mapController = MapController();
  final PolygonCacheService _polygonService = PolygonCacheService();
  final ApiService _apiService = ApiService();

  // FIX 1: Typed hit notifier — must be read synchronously inside onTap
  final LayerHitNotifier<String> _polygonHitNotifier = ValueNotifier(null);

  static const double _radiusKm = 1.0;

  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _isLoading = false;
  bool _isLoadingPolygons = false;
  String? _error;

  List<BuildingPolygon> _cachedPolygons = [];
  BuildingPolygon? _selectedPolygon;
  String? _cacheInfo;

  // FIX 2: populated fully before _rebuildOverlays is called
  Map<String, String> _customerNamesCache = {};

  List<Polygon> _polygonOverlays = [];
  List<Marker> _labelMarkers = [];

  String _syncProgressText = 'Loading buildings...';

  bool _mapReady = false;
  LatLng? _pendingCenter;

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  @override
  void dispose() {
    _polygonHitNotifier.dispose();
    super.dispose();
  }

  Future<void> _initializeLocation() async {
    try {
      loc.Location location = loc.Location();

      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) {
          if (!mounted) return;
          setState(() {
            _error = 'Location services are disabled. Please enable them.';
          });
          return;
        }
      }

      loc.PermissionStatus permissionGranted = await location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await location.requestPermission();
        if (permissionGranted != loc.PermissionStatus.granted) {
          if (!mounted) return;
          setState(() {
            _error = 'Location permission denied';
          });
          return;
        }
      }

      loc.LocationData locationData = await location.getLocation();

      // FIX 3: mounted guard before every setState in async methods
      if (!mounted) return;
      setState(() {
        _currentLocation =
            LatLng(locationData.latitude!, locationData.longitude!);

        if (widget.initialLat != null && widget.initialLon != null) {
          _selectedLocation = LatLng(widget.initialLat!, widget.initialLon!);
        } else {
          _selectedLocation = _currentLocation;
          widget.onLocationSelected(
              locationData.latitude!, locationData.longitude!);
        }
        _pendingCenter = _currentLocation;
      });

      if (_mapReady && _currentLocation != null) {
        _mapController.move(_currentLocation!, 16.0);
      }

      await _loadPolygonsForCurrentLocation();

      if (!mounted) return;
      if (_mapReady && _currentLocation != null) {
        _mapController.move(_currentLocation!, 16.0);
      } else {
        if (mounted) {
          setState(() {
            _pendingCenter = _currentLocation;
          });
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to get location: $e';
      });
    }
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

  Future<void> _loadPolygonsForCurrentLocation() async {
    if (_currentLocation == null) return;

    if (!mounted) return;
    setState(() {
      _isLoadingPolygons = true;
      _syncProgressText = 'Loading buildings...';
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSyncLat = prefs.getDouble('last_sync_lat');
      final lastSyncLon = prefs.getDouble('last_sync_lon');
      final curLat = _currentLocation!.latitude;
      final curLon = _currentLocation!.longitude;

      final movedFarEnough = lastSyncLat == null ||
          lastSyncLon == null ||
          _distanceMetres(curLat, curLon, lastSyncLat, lastSyncLon) > 300;

      final cachedPolygons =
          await _polygonService.getCachedPolygonsNearLocation(
        lat: curLat,
        lon: curLon,
        radiusKm: _radiusKm,
      );

      final stats = await _polygonService.getCacheStats();

      if (!mounted) return;
      setState(() {
        _cachedPolygons = cachedPolygons;
        _cacheInfo =
            '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
      });

      // FIX 2: Fetch ALL customer names first, then rebuild overlays ONCE
      await _fetchCustomerNamesForPolygons(cachedPolygons.take(30).toList());
      if (mounted) _rebuildOverlays();

      print('[MAP] Loaded ${cachedPolygons.length} cached polygons near current location');

      if (cachedPolygons.isEmpty ||
          await _polygonService.needsRefresh() ||
          movedFarEnough) {
        await _syncPolygons();
        await prefs.setDouble('last_sync_lat', curLat);
        await prefs.setDouble('last_sync_lon', curLon);
      } else {
        if (!mounted) return;
        setState(() {
          _isLoadingPolygons = false;
        });
      }
    } catch (e) {
      print('[MAP] Error loading polygons: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingPolygons = false;
      });
    }
  }

  Future<void> _syncPolygons() async {
    if (_currentLocation == null) return;

    if (!mounted) return;
    setState(() {
      _isLoadingPolygons = true;
      _syncProgressText = 'Syncing buildings...';
    });

    try {
      final result = await _polygonService.syncPolygonsForLocation(
        lat: _currentLocation!.latitude,
        lon: _currentLocation!.longitude,
        radiusKm: _radiusKm,
        onProgress: (fetched) {
          if (mounted) {
            setState(() {
              _syncProgressText = 'Syncing buildings... ($fetched fetched)';
            });
          }
        },
      );

      if (result.success) {
        final cachedPolygons =
            await _polygonService.getCachedPolygonsNearLocation(
          lat: _currentLocation!.latitude,
          lon: _currentLocation!.longitude,
          radiusKm: _radiusKm,
        );

        final stats = await _polygonService.getCacheStats();

        if (!mounted) return;
        setState(() {
          _cachedPolygons = cachedPolygons;
          _cacheInfo =
              '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
        });

        // FIX 2: Fetch ALL customer names first, then rebuild overlays ONCE
        await _fetchCustomerNamesForPolygons(cachedPolygons.take(30).toList());
        if (mounted) _rebuildOverlays();

        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble('last_sync_lat', _currentLocation!.latitude);
        await prefs.setDouble('last_sync_lon', _currentLocation!.longitude);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result.message),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
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
      if (!mounted) return;
      setState(() {
        _isLoadingPolygons = false;
      });
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      loc.Location location = loc.Location();
      loc.LocationData locationData = await location.getLocation();

      if (!mounted) return;
      setState(() {
        _currentLocation =
            LatLng(locationData.latitude!, locationData.longitude!);
        _selectedLocation = _currentLocation;
      });

      widget.onLocationSelected(
          locationData.latitude!, locationData.longitude!);

      _mapController.move(_currentLocation!, 18.5);

      await _loadPolygonsForCurrentLocation();
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

  // ─── FIX 1: Correct flutter_map v7 polygon tap pattern ───────────────────
  // The hitNotifier.value is read SYNCHRONOUSLY inside the GestureDetector
  // onTap callback — at the exact moment of the tap gesture. This is the
  // pattern documented by flutter_map v7. The old code called a separate
  // method (_onPolygonTap) which ran after the tap event, by which point
  // the notifier value could have been cleared.

  void _handlePolygonTap() {
    // Read synchronously — this is called directly from GestureDetector.onTap
    final hitResult = _polygonHitNotifier.value;
    if (hitResult == null || hitResult.hitValues.isEmpty) return;

    final buildingId = hitResult.hitValues.first;
    final matchingPolygons =
        _cachedPolygons.where((p) => p.buildingId == buildingId).toList();
    if (matchingPolygons.isEmpty) return;

    _showBuildingInfoPopup(matchingPolygons.first);
  }

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    // Check if a polygon was hit — if so, let the GestureDetector handle it
    final hitResult = _polygonHitNotifier.value;
    if (hitResult != null && hitResult.hitValues.isNotEmpty) return;

    if (!mounted) return;
    setState(() {
      _selectedLocation = position;
      _selectedPolygon = null;
    });
    widget.onLocationSelected(position.latitude, position.longitude);
  }

  // ─── FIX 2: Fetch ALL names, then return — caller calls _rebuildOverlays ──

  Future<void> _fetchCustomerNamesForPolygons(
      List<BuildingPolygon> polygons) async {
    final newNames = <String, String>{};
    for (var polygon in polygons) {
      if (!mounted) return;
      try {
        final result =
            await _apiService.getBuildingCustomers(polygon.buildingId);
        if (result['success'] == true && result['existingCustomers'] != null) {
          final customers = result['existingCustomers'] as List;
          if (customers.isNotEmpty) {
            final name = (customers[0]['name'] as String?) ??
                (customers[0]['label'] as String? ?? polygon.buildingId);
            newNames[polygon.buildingId] = name;
          }
        }
      } catch (e) {
        // Non-fatal — skip label for this building
      }
    }
    if (!mounted) return;
    // Merge and update state once
    setState(() {
      _customerNamesCache = {..._customerNamesCache, ...newNames};
    });
  }

  // ─── FIX 2 + FIX 3: Rebuild overlays once, with mounted guard ─────────────

  void _rebuildOverlays() {
    if (!mounted) return;

    final overlays = <Polygon>[];
    final labelMarkers = <Marker>[];

    print('[MAP] _rebuildOverlays: ${_cachedPolygons.length} polygons');

    for (final bp in _cachedPolygons) {
      try {
        final geometryJson = jsonDecode(bp.geometry);
        final rings = geometryJson['rings'] as List;
        if (rings.isEmpty) continue;

        final ring = rings[0] as List;
        final points = ring.map<LatLng>((coord) {
          final lat = (coord[1] is int)
              ? (coord[1] as int).toDouble()
              : coord[1] as double;
          final lon = (coord[0] is int)
              ? (coord[0] as int).toDouble()
              : coord[0] as double;
          return LatLng(lat, lon);
        }).toList();

        if (points.length < 3) continue;

        final isSelected = _selectedPolygon?.buildingId == bp.buildingId;
        final isCaptured = _customerNamesCache.containsKey(bp.buildingId);
        final polygonColor = _getPolygonColor(bp.buildingId);

        overlays.add(Polygon(
          points: points,
          hitValue: bp.buildingId,
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

        final center = _getPolygonCenter(points);

        // FIX 4: Building ID label — stronger shadows, taller marker
        labelMarkers.add(Marker(
          point: center,
          width: 100,
          height: 20,
          child: IgnorePointer(
            child: Text(
              bp.buildingId,
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

        // Business name label — only for captured buildings
        if (isCaptured) {
          final businessName = _customerNamesCache[bp.buildingId]!;
          labelMarkers.add(Marker(
            point: LatLng(center.latitude + 0.00005, center.longitude),
            width: 130,
            height: 24,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showExistingCustomersDialog(bp),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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
      } catch (e) {
        print('Error building overlay for ${bp.buildingId}: $e');
      }
    }

    print('[MAP] Built ${overlays.length} overlays, ${labelMarkers.length} labels');

    setState(() {
      _polygonOverlays = overlays;
      _labelMarkers = labelMarkers;
    });
  }

  Color _getPolygonColor(String buildingId) {
    final colors = [
      const Color(0xFFE91E63),
      const Color(0xFF9C27B0),
      const Color(0xFF3F51B5),
      const Color(0xFF2196F3),
      const Color(0xFF009688),
      const Color(0xFF4CAF50),
      const Color(0xFFFFC107),
      const Color(0xFFFF9800),
      const Color(0xFFFF5722),
      const Color(0xFFF44336),
    ];
    return colors[buildingId.hashCode.abs() % colors.length];
  }

  LatLng _getPolygonCenter(List<LatLng> points) {
    if (points.isEmpty) return const LatLng(0, 0);
    double sumLat = 0, sumLon = 0;
    for (var p in points) {
      sumLat += p.latitude;
      sumLon += p.longitude;
    }
    return LatLng(sumLat / points.length, sumLon / points.length);
  }

  // ─── Dialogs ───────────────────────────────────────────────────────────────

  void _showExistingCustomersDialog(BuildingPolygon polygon) async {
    try {
      final result = await _apiService.getBuildingCustomers(polygon.buildingId);

      if (result['success'] != true || result['existingCustomers'] == null) {
        _selectPolygonDirectly(polygon);
        return;
      }

      final existingCustomers = result['existingCustomers'] as List;
      if (existingCustomers.isEmpty) {
        _selectPolygonDirectly(polygon);
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
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Building: ${polygon.buildingId}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      const SizedBox(height: 8),
                      Text(
                          'This building has ${existingCustomers.length} registered customer(s):',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade700)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Select a customer to add pickup:',
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 12),
                ...existingCustomers.map((customer) => InkWell(
                      onTap: () {
                        Navigator.of(context).pop();
                        _selectPolygonDirectly(polygon);
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: customer['label']
                                        .toString()
                                        .startsWith('R')
                                    ? Colors.blue.shade700
                                    : Colors.orange.shade700,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(customer['label'] as String,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14)),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(customer['name'] as String,
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14)),
                                  Text(customer['email'] as String,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade600)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                _selectPolygonDirectly(polygon);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade700),
              child: const Text('Add New Pickup',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    } catch (e) {
      _selectPolygonDirectly(polygon);
    }
  }

  void _showBuildingInfoPopup(BuildingPolygon polygon) async {
    try {
      final result = await _apiService.getBuildingCustomers(polygon.buildingId);

      if (result['success'] == true && result['existingCustomers'] != null) {
        final existingCustomers = result['existingCustomers'] as List;
        final customerCount = existingCustomers.length;

        if (customerCount > 0 && mounted) {
          final shouldContinue = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade700,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.warning,
                        color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'ADD NEW CUSTOMER',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange),
                    ),
                  ),
                ],
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Building: ${polygon.buildingId}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14)),
                          const SizedBox(height: 8),
                          Text(
                            'This building already has $customerCount registered customer(s). '
                            'Do you want to add a new customer anyway?',
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey.shade700),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade700),
                  child: const Text('Add New Customer',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );

          if (shouldContinue != true) return;
        }
      }
    } catch (e) {
      // Non-fatal — proceed to select polygon
    }

    _selectPolygonDirectly(polygon);
  }

  void _selectPolygonDirectly(BuildingPolygon polygon) {
    if (!mounted) return;
    setState(() {
      _selectedPolygon = polygon;
      _selectedLocation = LatLng(polygon.centerLat, polygon.centerLon);
    });

    widget.onLocationSelected(polygon.centerLat, polygon.centerLon);
    widget.onBuildingSelected?.call(polygon);

    // Rebuild so selected polygon gets highlighted
    _rebuildOverlays();
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error, color: Colors.red, size: 48),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _initializeLocation,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter:
                        _selectedLocation ?? const LatLng(6.5795, 3.3549),
                    initialZoom: 16.0,
                    onTap: _onMapTap,
                    onMapReady: () {
                      _mapReady = true;
                      final center = _pendingCenter ?? _currentLocation;
                      if (center != null) {
                        _mapController.move(center, 16.0);
                        if (mounted) {
                          setState(() {
                            _pendingCenter = null;
                          });
                        }
                      }
                    },
                  ),
                  children: [
                    // Satellite imagery base layer
                    // fallbackUrl: if ArcGIS tiles fail (network error, timeout,
                    // SSL issue), flutter_map v7 automatically retries with OSM.
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      fallbackUrl:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.mottainai.survey',
                      maxZoom: 19,
                      // Reduce panBuffer to 0 on mobile to avoid overwhelming
                      // the tile server with preload requests on slow connections
                      panBuffer: 0,
                    ),
                    // Place name overlay — only load if on ArcGIS (skip on OSM fallback)
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                      fallbackUrl:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.mottainai.survey',
                      maxZoom: 19,
                      panBuffer: 0,
                      // Opacity 0 on fallback — OSM already has labels built in
                      opacity: 0.85,
                    ),
                    // FIX 1: GestureDetector wraps PolygonLayer.
                    // hitNotifier.value is read SYNCHRONOUSLY inside onTap —
                    // this is the correct flutter_map v7 pattern.
                    GestureDetector(
                      behavior: HitTestBehavior.deferToChild,
                      onTap: _handlePolygonTap,
                      child: PolygonLayer(
                        polygons: _polygonOverlays,
                        hitNotifier: _polygonHitNotifier,
                        simplificationTolerance: 0,
                      ),
                    ),
                    // FIX 4: Label markers above polygon layer
                    MarkerLayer(markers: _labelMarkers),
                    // Selected location pin
                    if (_selectedLocation != null && _selectedPolygon == null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _selectedLocation!,
                            width: 40,
                            height: 40,
                            child: const Icon(Icons.location_pin,
                                color: Colors.red, size: 40),
                          ),
                        ],
                      ),
                    // Current GPS location dot
                    if (_currentLocation != null &&
                        _currentLocation != _selectedLocation)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _currentLocation!,
                            width: 30,
                            height: 30,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.blue.withValues(alpha: 0.3),
                                shape: BoxShape.circle,
                                border:
                                    Border.all(color: Colors.blue, width: 2),
                              ),
                              child: const Icon(Icons.my_location,
                                  color: Colors.blue, size: 16),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                // Loading indicator
                if (_isLoadingPolygons)
                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(_syncProgressText),
                        ],
                      ),
                    ),
                  ),
                // Cache info badge
                if (!_isLoadingPolygons && _cacheInfo != null)
                  Positioned(
                    top: 10,
                    left: 10,
                    right: 60,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.business,
                              size: 16, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '$_cacheInfo | overlays:${_polygonOverlays.length}',
                              style: const TextStyle(fontSize: 11)),
                          ),
                        ],
                      ),
                    ),
                  ),
                // GPS button
                Positioned(
                  right: 10,
                  bottom: 70,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: _getCurrentLocation,
                    backgroundColor: Colors.white,
                    child: const Icon(Icons.my_location, color: Colors.blue),
                  ),
                ),
                // Refresh button
                Positioned(
                  right: 10,
                  bottom: 10,
                  child: FloatingActionButton(
                    mini: true,
                    onPressed: _isLoadingPolygons ? null : _syncPolygons,
                    backgroundColor: Colors.white,
                    child: _isLoadingPolygons
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, color: Colors.green),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_selectedPolygon != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Row(
              children: [
                const Icon(Icons.business, size: 20, color: Colors.blue),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Building: ${_selectedPolygon!.buildingId}',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
                      if (_selectedPolygon!.businessName != null)
                        Text(_selectedPolygon!.businessName!,
                            style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          )
        else if (_selectedLocation != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.location_on, size: 20, color: Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Lat: ${_selectedLocation!.latitude.toStringAsFixed(6)}, '
                    'Lon: ${_selectedLocation!.longitude.toStringAsFixed(6)}',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
