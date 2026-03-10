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
import 'building_info_popup.dart';

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

  // Use the same radius everywhere so cache queries match what was synced
  // 1km gives a comfortable coverage area without overwhelming the connection
  static const double _radiusKm = 1.0;

  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _isLoading = false;
  bool _isLoadingPolygons = false;
  String? _error;

  List<BuildingPolygon> _cachedPolygons = [];
  BuildingPolygon? _selectedPolygon;
  String? _cacheInfo;

  // Map of buildingId → customer name (only for captured buildings)
  Map<String, String> _customerNamesCache = {};

  // Pre-built polygon overlays — rebuilt only when _cachedPolygons changes
  List<Polygon> _polygonOverlays = [];
  // Labels only for captured buildings (show business name)
  List<Marker> _capturedLabels = [];

  // flutter_map v7 hit notifier for polygon tap detection
  final LayerHitNotifier<String> _polygonHitNotifier = ValueNotifier(null);

  // Sync progress text shown during loading
  String _syncProgressText = 'Loading buildings...';

  // Track whether the FlutterMap controller is ready to accept move() calls
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
          setState(() {
            _error = 'Location permission denied';
          });
          return;
        }
      }

      loc.LocationData locationData = await location.getLocation();

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
      });

      // Store the GPS location as pending center.
      // The actual move() is called in _onMapReady() once the FlutterMap
      // controller is ready — this avoids the race condition where move()
      // is called before the map has finished its first layout.
      setState(() {
        _pendingCenter = _currentLocation;
      });
      if (_mapReady && _currentLocation != null) {
        // Zoom 16 covers ~800m × 800m — enough to see nearby buildings
        _mapController.move(_currentLocation!, 16.0);
      }

      await _loadPolygonsForCurrentLocation();

      // Re-center after polygons load in case the map drifted
      if (_mapReady && _currentLocation != null) {
        _mapController.move(_currentLocation!, 16.0);
      } else {
        setState(() {
          _pendingCenter = _currentLocation;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to get location: $e';
      });
    }
  }

  /// Returns distance in metres between two lat/lon points (Haversine formula).
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

      // Check if GPS has moved more than 300m from the last sync centre.
      // If so, force a fresh ArcGIS sync so polygons are centred on the user.
      final movedFarEnough = lastSyncLat == null ||
          lastSyncLon == null ||
          _distanceMetres(curLat, curLon, lastSyncLat, lastSyncLon) > 300;

      // Use the same radius as the sync so we only query what was actually cached
      final cachedPolygons =
          await _polygonService.getCachedPolygonsNearLocation(
        lat: curLat,
        lon: curLon,
        radiusKm: _radiusKm,
      );

      final stats = await _polygonService.getCacheStats();

      setState(() {
        _cachedPolygons = cachedPolygons;
        _cacheInfo =
            '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
      });

      // Rebuild overlays after updating polygons
      _rebuildOverlays();

      print('[MAP] Loaded ${cachedPolygons.length} cached polygons near current location');
      print('[MAP] GPS: ($curLat, $curLon), lastSync: ($lastSyncLat, $lastSyncLon), movedFarEnough: $movedFarEnough');
      if (cachedPolygons.isNotEmpty) {
        print(
            '[MAP] First polygon: ${cachedPolygons[0].buildingId} at (${cachedPolygons[0].centerLat}, ${cachedPolygons[0].centerLon})');
      }

      // Fetch customer names for captured buildings (nearest 30)
      _fetchCustomerNamesForPolygons(cachedPolygons.take(30).toList());

      // Sync from ArcGIS if:
      //  - cache is empty
      //  - cache is stale (> 7 days)
      //  - GPS has moved more than 300m from last sync centre
      if (cachedPolygons.isEmpty ||
          await _polygonService.needsRefresh() ||
          movedFarEnough) {
        await _syncPolygons();
        // Save the new sync centre
        await prefs.setDouble('last_sync_lat', curLat);
        await prefs.setDouble('last_sync_lon', curLon);
      } else {
        setState(() {
          _isLoadingPolygons = false;
        });
      }
    } catch (e) {
      print('[MAP] Error loading polygons: $e');
      setState(() {
        _isLoadingPolygons = false;
      });
    }
  }

  Future<void> _syncPolygons() async {
    if (_currentLocation == null) return;

    setState(() {
      _isLoadingPolygons = true;
    });

    try {
      setState(() {
        _syncProgressText = 'Syncing buildings...';
      });

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

        setState(() {
          _cachedPolygons = cachedPolygons;
          _cacheInfo =
              '${stats.polygonCount} buildings cached • ${stats.lastUpdatedText}';
        });

        _rebuildOverlays();

        // Persist the sync centre so future opens don't re-sync unnecessarily
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
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoadingPolygons = false;
      });
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      loc.Location location = loc.Location();
      loc.LocationData locationData = await location.getLocation();

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

  // ─── Polygon tap via flutter_map v7 hitNotifier ────────────────────────────

  /// Called when the GestureDetector wrapping PolygonLayer detects a tap.
  /// Reads the hitNotifier to find which polygon was tapped.
  void _onPolygonTap() {
    final hitResult = _polygonHitNotifier.value;
    if (hitResult == null || hitResult.hitValues.isEmpty) return;

    // hitValues is ordered top-to-bottom; take the topmost (first) polygon
    final buildingId = hitResult.hitValues.first;
    final tappedPolygon = _cachedPolygons.firstWhere(
      (p) => p.buildingId == buildingId,
      orElse: () => _cachedPolygons.first,
    );

    _showBuildingInfoPopup(tappedPolygon);
  }

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    // If a polygon was tapped, the GestureDetector around PolygonLayer handles it.
    // This handler only fires when tapping empty map space.
    final hitResult = _polygonHitNotifier.value;
    if (hitResult != null && hitResult.hitValues.isNotEmpty) {
      // A polygon was under the tap — let the polygon GestureDetector handle it
      return;
    }

    setState(() {
      _selectedLocation = position;
      _selectedPolygon = null;
    });
    widget.onLocationSelected(position.latitude, position.longitude);
  }

  /// Fetch customer names for captured buildings — limited to [polygons] to avoid API overload.
  Future<void> _fetchCustomerNamesForPolygons(
      List<BuildingPolygon> polygons) async {
    for (var polygon in polygons) {
      if (!mounted) return;
      try {
        final result =
            await _apiService.getBuildingCustomers(polygon.buildingId);
        if (result['success'] == true && result['existingCustomers'] != null) {
          final customers = result['existingCustomers'] as List;
          if (customers.isNotEmpty) {
            // Use the first customer's business name as the label
            final name = (customers[0]['name'] as String?) ??
                (customers[0]['label'] as String? ?? polygon.buildingId);
            if (mounted) {
              setState(() {
                _customerNamesCache[polygon.buildingId] = name;
              });
              // Rebuild labels layer to show updated labels
              _rebuildOverlays();
            }
          }
        }
      } catch (e) {
        // Non-fatal — skip label for this building
      }
    }
  }

  // ─── Overlay builders (called once after data changes, not on every build) ───

  /// Rebuild both polygon fill layer and captured-building label marker layer.
  /// Call this after _cachedPolygons or _customerNamesCache changes.
  void _rebuildOverlays() {
    final overlays = <Polygon>[];
    final capturedLabels = <Marker>[];

    print('[MAP] _rebuildOverlays called with ${_cachedPolygons.length} polygons');

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

        // ── Polygon fill + border ──
        overlays.add(Polygon(
          points: points,
          // hitValue enables flutter_map v7 hit detection
          hitValue: bp.buildingId,
          // color controls fill; non-null = filled
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

        // ── Building ID label — always shown on the polygon (small, subtle) ──
        // This is a tiny text marker sitting at the polygon center
        capturedLabels.add(Marker(
          point: center,
          width: 90,
          height: 16,
          child: IgnorePointer(
            // Building ID labels don't intercept taps — polygon GestureDetector handles it
            child: Text(
              bp.buildingId,
              style: TextStyle(
                color: isCaptured
                    ? Colors.green.shade900
                    : Colors.blue.shade900,
                fontSize: 7,
                fontWeight: FontWeight.bold,
                shadows: const [
                  Shadow(
                    color: Colors.white,
                    blurRadius: 3,
                    offset: Offset(0, 0),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ));

        // ── Business name label — only for captured buildings ──
        if (isCaptured) {
          final businessName = _customerNamesCache[bp.buildingId]!;
          capturedLabels.add(Marker(
            point: LatLng(center.latitude + 0.00004, center.longitude),
            width: 120,
            height: 22,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => _showExistingCustomersDialog(bp),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.shade700.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.white, width: 1),
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

    print('[MAP] Built ${overlays.length} polygon overlays, ${capturedLabels.length} labels');

    setState(() {
      _polygonOverlays = overlays;
      _capturedLabels = capturedLabels;
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
    // Check for existing customers first
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
                        border:
                            Border.all(color: Colors.orange.shade300, width: 2),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(Icons.info_outline,
                                color: Colors.orange.shade700, size: 20),
                            const SizedBox(width: 8),
                            const Expanded(
                                child: Text('WARNING: Existing Customers',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14))),
                          ]),
                          const SizedBox(height: 8),
                          Text(
                              'This building already has $customerCount registered customer(s):',
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade700)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...existingCustomers.map((customer) => Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: customer['label']
                                          .toString()
                                          .startsWith('R')
                                      ? Colors.blue.shade700
                                      : Colors.orange.shade700,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(customer['label'] as String,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(customer['name'] as String,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13)),
                                    Text(customer['email'] as String,
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey.shade600)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade300),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.help_outline,
                              color: Colors.red.shade700, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Are you sure you want to create a NEW customer account for this building?',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13),
                            ),
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
                  child: const Text('Yes, Add New Customer',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );

          if (shouldContinue != true) return;
        }
      }
    } catch (e) {
      // Continue anyway if check fails
    }

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => BuildingInfoPopup(
        polygon: polygon,
        onConfirm: (updatedPolygon) {
          setState(() {
            _selectedPolygon = updatedPolygon;
            _selectedLocation =
                LatLng(updatedPolygon.centerLat, updatedPolygon.centerLon);
          });
          _rebuildOverlays();
          widget.onLocationSelected(
              updatedPolygon.centerLat, updatedPolygon.centerLon);
          widget.onBuildingSelected?.call(updatedPolygon);
        },
      ),
    );
  }

  void _selectPolygonDirectly(BuildingPolygon polygon) {
    showDialog(
      context: context,
      builder: (context) => BuildingInfoPopup(
        polygon: polygon,
        onConfirm: (updatedPolygon) {
          setState(() {
            _selectedPolygon = updatedPolygon;
            _selectedLocation =
                LatLng(updatedPolygon.centerLat, updatedPolygon.centerLon);
          });
          _rebuildOverlays();
          widget.onLocationSelected(
              updatedPolygon.centerLat, updatedPolygon.centerLon);
          widget.onBuildingSelected?.call(updatedPolygon);
        },
      ),
    );
  }

  // ─── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        height: 400,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Getting your location...'),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Container(
        height: 400,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.red),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text(_error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _error = null;
                    });
                    _initializeLocation();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 400,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey),
            borderRadius: BorderRadius.circular(8),
          ),
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
                      // If GPS was obtained before the map was ready, move now
                      final center = _pendingCenter ?? _currentLocation;
                      if (center != null) {
                        _mapController.move(center, 16.0);
                        setState(() {
                          _pendingCenter = null;
                        });
                      }
                    },
                  ),
                  children: [
                    // Satellite imagery base layer
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.mottainai.survey',
                      maxZoom: 19,
                    ),
                    // Place name overlay
                    TileLayer(
                      urlTemplate:
                          'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.mottainai.survey',
                      maxZoom: 19,
                    ),
                    // Building polygon fills with flutter_map v7 hit detection
                    // GestureDetector wraps the layer to intercept taps on polygons
                    GestureDetector(
                      behavior: HitTestBehavior.deferToChild,
                      onTap: _onPolygonTap,
                      child: PolygonLayer(
                        polygons: _polygonOverlays,
                        hitNotifier: _polygonHitNotifier,
                        simplificationTolerance: 0,
                      ),
                    ),
                    // Building ID labels + captured business name labels
                    MarkerLayer(markers: _capturedLabels),
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
