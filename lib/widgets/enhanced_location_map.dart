import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;
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
  static const double _radiusKm = 0.5;

  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _isLoading = false;
  bool _isLoadingPolygons = false;
  String? _error;

  List<BuildingPolygon> _cachedPolygons = [];
  BuildingPolygon? _selectedPolygon;
  String? _cacheInfo;
  Map<String, String> _customerLabelsCache = {};

  // Pre-built polygon overlays — rebuilt only when _cachedPolygons changes
  List<Polygon> _polygonOverlays = [];
  List<Marker> _polygonLabels = [];

  @override
  void initState() {
    super.initState();
    _initializeLocation();
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

      // Move map to current location after first frame
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedLocation != null) {
          _mapController.move(_selectedLocation!, 18.5);
        }
      });

      await _loadPolygonsForCurrentLocation();
    } catch (e) {
      setState(() {
        _error = 'Failed to get location: $e';
      });
    }
  }

  Future<void> _loadPolygonsForCurrentLocation() async {
    if (_currentLocation == null) return;

    setState(() {
      _isLoadingPolygons = true;
    });

    try {
      // Use the same radius as the sync so we only query what was actually cached
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

      // Rebuild overlays after updating polygons
      _rebuildOverlays();

      print('Loaded ${cachedPolygons.length} cached polygons near current location');
      if (cachedPolygons.isNotEmpty) {
        print(
            'First polygon: ${cachedPolygons[0].buildingId} at (${cachedPolygons[0].centerLat}, ${cachedPolygons[0].centerLon})');
      }

      // Fetch customer labels only for the nearest 20 buildings to avoid API overload
      _fetchCustomerLabelsForPolygons(cachedPolygons.take(20).toList());

      // Sync from ArcGIS if cache is empty or stale
      if (cachedPolygons.isEmpty || await _polygonService.needsRefresh()) {
        await _syncPolygons();
      } else {
        setState(() {
          _isLoadingPolygons = false;
        });
      }
    } catch (e) {
      print('Error loading polygons: $e');
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
      final result = await _polygonService.syncPolygonsForLocation(
        lat: _currentLocation!.latitude,
        lon: _currentLocation!.longitude,
        radiusKm: _radiusKm,
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

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    BuildingPolygon? tappedPolygon = _findPolygonAtPoint(position);

    if (tappedPolygon != null) {
      _showBuildingInfoPopup(tappedPolygon);
    } else {
      setState(() {
        _selectedLocation = position;
        _selectedPolygon = null;
      });
      widget.onLocationSelected(position.latitude, position.longitude);
    }
  }

  BuildingPolygon? _findPolygonAtPoint(LatLng point) {
    for (var polygon in _cachedPolygons) {
      if (_isPointInPolygon(point, polygon)) {
        return polygon;
      }
    }
    return null;
  }

  bool _isPointInPolygon(LatLng point, BuildingPolygon polygon) {
    try {
      final geometryJson = jsonDecode(polygon.geometry);
      final rings = geometryJson['rings'] as List;
      if (rings.isEmpty) return false;

      final ring = rings[0] as List;
      bool inside = false;
      int j = ring.length - 1;

      for (int i = 0; i < ring.length; i++) {
        final xi = (ring[i][0] is int)
            ? (ring[i][0] as int).toDouble()
            : ring[i][0] as double;
        final yi = (ring[i][1] is int)
            ? (ring[i][1] as int).toDouble()
            : ring[i][1] as double;
        final xj = (ring[j][0] is int)
            ? (ring[j][0] as int).toDouble()
            : ring[j][0] as double;
        final yj = (ring[j][1] is int)
            ? (ring[j][1] as int).toDouble()
            : ring[j][1] as double;

        final intersect = ((yi > point.latitude) != (yj > point.latitude)) &&
            (point.longitude <
                (xj - xi) * (point.latitude - yi) / (yj - yi) + xi);

        if (intersect) inside = !inside;
        j = i;
      }

      return inside;
    } catch (e) {
      return false;
    }
  }

  /// Fetch customer labels — limited to [polygons] (max 20) to avoid API overload.
  Future<void> _fetchCustomerLabelsForPolygons(
      List<BuildingPolygon> polygons) async {
    for (var polygon in polygons) {
      if (!mounted) return;
      try {
        final result =
            await _apiService.getBuildingCustomers(polygon.buildingId);
        if (result['success'] == true && result['existingCustomers'] != null) {
          final customers = result['existingCustomers'] as List;
          if (customers.isNotEmpty) {
            final labels =
                customers.map((c) => c['label'] as String).join(',');
            if (mounted) {
              setState(() {
                _customerLabelsCache[polygon.buildingId] = labels;
              });
              // Rebuild labels layer to show updated colours
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

  /// Rebuild both polygon fill layer and label marker layer.
  /// Call this after _cachedPolygons or _customerLabelsCache changes.
  void _rebuildOverlays() {
    final overlays = <Polygon>[];
    final labels = <Marker>[];

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

        if (points.isEmpty) continue;

        final isSelected = _selectedPolygon?.buildingId == bp.buildingId;
        final polygonColor = _getPolygonColor(bp.buildingId);

        overlays.add(Polygon(
          points: points,
          color: isSelected
              ? Colors.blue.withOpacity(0.4)
              : polygonColor.withOpacity(0.25),
          borderColor: isSelected ? Colors.blue : polygonColor,
          borderStrokeWidth: isSelected ? 4.0 : 2.0,
          isFilled: true,
        ));

        // Label — only shown when zoom >= 17 (handled by keeping markers small)
        final center = _getPolygonCenter(points);
        final customerLabels = _customerLabelsCache[bp.buildingId];
        final hasCustomers =
            customerLabels != null && customerLabels.isNotEmpty;
        final labelColor =
            hasCustomers ? Colors.green.shade700 : Colors.blue.shade700;
        final displayText = bp.buildingId;

        labels.add(Marker(
          point: center,
          width: 110,
          height: 22,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (hasCustomers) {
                _showExistingCustomersDialog(bp);
              } else {
                _selectPolygonDirectly(bp);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: labelColor.withOpacity(0.85),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white, width: 1),
              ),
              child: Text(
                displayText,
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
      } catch (e) {
        print('Error building overlay for ${bp.buildingId}: $e');
      }
    }

    setState(() {
      _polygonOverlays = overlays;
      _polygonLabels = labels;
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
                            Icon(Icons.arrow_forward_ios,
                                size: 16, color: Colors.grey.shade400),
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
          ],
        ),
      );
    } catch (e) {
      _selectPolygonDirectly(polygon);
    }
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

  void _showBuildingInfoPopup(BuildingPolygon polygon) async {
    try {
      final result = await _apiService.checkBuilding(polygon.buildingId);

      if (result['success'] == true && result['hasCustomers'] == true) {
        final existingCustomers = result['existingCustomers'] as List;
        final customerCount = result['customerCount'] as int;

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
                  child:
                      const Icon(Icons.warning, color: Colors.white, size: 24),
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
    } catch (e) {
      // Continue anyway if check fails
    }

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
                    initialZoom: 18.5,
                    onTap: _onMapTap,
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
                    // Building polygon fills (pre-built, not rebuilt on every frame)
                    PolygonLayer(polygons: _polygonOverlays),
                    // Building ID labels (pre-built)
                    MarkerLayer(markers: _polygonLabels),
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
                                color: Colors.blue.withOpacity(0.3),
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
                        color: Colors.white.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Loading buildings...'),
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
                        color: Colors.white.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.business,
                              size: 16, color: Colors.green),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(_cacheInfo!,
                                style: const TextStyle(fontSize: 12)),
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
