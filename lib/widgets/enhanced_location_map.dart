import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;
import '../models/building_polygon.dart';
import '../models/customer_point.dart';
import '../services/arcgis_service.dart';

// ─── Isolate helper ───────────────────────────────────────────────────────────
// compute() only supports plain Dart types. Custom class instances (LatLng)
// are NOT isolate-safe. The isolate returns primitives; LatLng is built on
// the main thread.

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
        if (lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0) continue;
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
    } catch (_) {}
  }
  return result;
}

// Lightweight struct — main thread only
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

enum _LoadPhase { idle, locating, loading, ready, error }

class _EnhancedLocationMapState extends State<EnhancedLocationMap> {
  final MapController _mapController = MapController();
  final ArcGISService _arcgis = ArcGISService();

  // Label zoom threshold — chips only appear at zoom ≥ 15
  static const double _labelZoomThreshold = 15.0;

  // ─── State ──────────────────────────────────────────────────────────────────

  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _mapReady = false;
  LatLng? _pendingCenter;

  _LoadPhase _phase = _LoadPhase.idle;
  String _statusText = '';
  String? _errorText;

  // Decoded polygon render data (from compute isolate)
  List<_PolygonRenderData> _allPolygonData = [];

  // Viewport-filtered render lists
  List<Polygon> _visiblePolygons = [];
  List<Marker> _visibleMarkers = [];

  // Live data from ArcGIS
  List<BuildingPolygon> _livePolygons = [];
  Map<String, List<CustomerPoint>> _liveCustomers = {};

  // Currently selected polygon
  BuildingPolygon? _selectedPolygon;

  // Camera state
  LatLngBounds? _currentBounds;
  double _currentZoom = 18.5;
  Timer? _cullingDebounce;
  Timer? _viewportDebounce;

  // Track last viewport to avoid redundant queries
  LatLngBounds? _lastQueriedBounds;

  @override
  void initState() {
    super.initState();
    _startLocate();
  }

  @override
  void dispose() {
    _cullingDebounce?.cancel();
    _viewportDebounce?.cancel();
    super.dispose();
  }

  // ─── Phase 1: Get GPS location ───────────────────────────────────────────────

  Future<void> _startLocate() async {
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

      // Move map to GPS location — use postFrameCallback to ensure
      // MapController is fully attached regardless of build timing.
      if (_mapReady) {
        _mapController.move(currentLoc, 18.5);
        _pendingCenter = null;
      } else {
        // onMapReady will pick up _pendingCenter once the map is ready
        // (already set above via setState)
      }

      // Load polygons around GPS location immediately
      await _loadPolygonsNearLocation(currentLoc);
    } catch (e) {
      _setError('Failed to get location: $e');
    }
  }

  // ─── Load polygons near a point (initial load) ───────────────────────────────

  Future<void> _loadPolygonsNearLocation(LatLng center) async {
    if (!mounted) return;
    setState(() {
      _phase = _LoadPhase.loading;
      _statusText = 'Loading buildings...';
    });

    try {
      // Use 0.5km radius for initial load — fast and focused on user location
      final polygons = await _arcgis.fetchPolygonsNearLocation(
        lat: center.latitude,
        lon: center.longitude,
        radiusKm: 0.5,
        onProgress: (n) {
          if (mounted) setState(() => _statusText = 'Loading buildings... ($n)');
        },
      );

      if (!mounted) return;

      _livePolygons = polygons;
      await _decodeAndRender(polygons);

      // Fetch customers for all loaded polygons
      if (polygons.isNotEmpty) {
        unawaited(_fetchAndRenderCustomers(polygons));
      }

      if (mounted) {
        setState(() {
          _phase = _LoadPhase.ready;
          _statusText = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _LoadPhase.error;
          _errorText = 'Failed to load buildings: $e';
        });
      }
    }
  }

  // ─── Load polygons for viewport (on map move) ────────────────────────────────

  Future<void> _loadPolygonsForViewport(LatLngBounds bounds) async {
    if (!mounted) return;

    // Skip if bounds haven't changed significantly
    if (_lastQueriedBounds != null &&
        _boundsOverlapRatio(bounds, _lastQueriedBounds!) > 0.8) {
      return;
    }

    _lastQueriedBounds = bounds;

    setState(() {
      _phase = _LoadPhase.loading;
      _statusText = 'Loading buildings...';
    });

    try {
      final polygons = await _arcgis.fetchPolygonsInViewport(
        minLat: bounds.south,
        maxLat: bounds.north,
        minLon: bounds.west,
        maxLon: bounds.east,
      );

      if (!mounted) return;

      // Merge with existing polygons (avoid duplicates by buildingId)
      final existingIds = _livePolygons.map((p) => p.buildingId).toSet();
      final newPolygons = polygons
          .where((p) => !existingIds.contains(p.buildingId))
          .toList();

      _livePolygons = [..._livePolygons, ...newPolygons];
      await _decodeAndRender(_livePolygons);

      // Fetch customers for newly loaded polygons only
      if (newPolygons.isNotEmpty) {
        unawaited(_fetchAndRenderCustomers(newPolygons));
      }

      if (mounted) {
        setState(() {
          _phase = _LoadPhase.ready;
          _statusText = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _LoadPhase.ready; // Don't block map on viewport query failure
          _statusText = '';
        });
        print('[Map] Viewport query failed: $e');
      }
    }
  }

  /// Returns the overlap ratio between two bounds (0.0–1.0).
  double _boundsOverlapRatio(LatLngBounds a, LatLngBounds b) {
    final latOverlap = math.max(
        0.0,
        math.min(a.north, b.north) - math.max(a.south, b.south));
    final lonOverlap = math.max(
        0.0,
        math.min(a.east, b.east) - math.max(a.west, b.west));
    final areaA = (a.north - a.south) * (a.east - a.west);
    if (areaA <= 0) return 0.0;
    return (latOverlap * lonOverlap) / areaA;
  }

  // ─── Decode polygons in isolate + render ─────────────────────────────────────

  Future<void> _decodeAndRender(List<BuildingPolygon> polygons) async {
    final input = polygons
        .map((p) => {'buildingId': p.buildingId, 'geometry': p.geometry})
        .toList();

    final decoded = await compute(_decodePolygonsInIsolate, input);
    if (!mounted) return;

    final renderData = decoded.map((d) {
      final pts = (d['points'] as List)
          .map((p) => LatLng((p as List)[0] as double, p[1] as double))
          .toList();
      return _PolygonRenderData(
        buildingId: d['buildingId'] as String,
        points: pts,
        center: LatLng(
            d['centerLat'] as double, d['centerLon'] as double),
      );
    }).toList();

    setState(() {
      _allPolygonData = renderData;
    });

    // Always render without bounds filter on the initial load.
    // _currentBounds may be set from the programmatic GPS move in onMapReady,
    // but the bounds captured at that instant can be slightly off and cull all
    // polygons before they have a chance to render. Rendering without filter
    // first guarantees polygons are visible immediately; the viewport culling
    // debounce in onPositionChanged will take over on the next user gesture.
    _renderPolygons(useBoundsFilter: false);

    // Schedule a second render after the frame so _currentBounds is stable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _allPolygonData.isNotEmpty) {
        _renderPolygons(useBoundsFilter: _currentBounds != null);
      }
    });
  }

  // ─── Fetch customers from ArcGIS Customer Layer ───────────────────────────────

  Future<void> _fetchAndRenderCustomers(
      List<BuildingPolygon> polygons) async {
    if (polygons.isEmpty || !mounted) return;

    final ids = polygons.map((p) => p.buildingId).toList();
    final customers = await _arcgis.fetchCustomersForBuildings(ids);

    if (!mounted) return;

    setState(() {
      _liveCustomers = {..._liveCustomers, ...customers};
    });

    _renderPolygons(useBoundsFilter: _currentBounds != null);
  }

  // ─── Render polygons + labels ─────────────────────────────────────────────────

  void _renderPolygons({bool useBoundsFilter = false}) {
    if (!mounted) return;

    final visiblePolygons = <Polygon>[];
    final visibleMarkers = <Marker>[];

    for (final pd in _allPolygonData) {
      // Viewport culling
      if (useBoundsFilter && _currentBounds != null) {
        final inBounds = pd.points.any((p) =>
            _currentBounds!.contains(p));
        if (!inBounds) continue;
      }

      final isSelected = _selectedPolygon?.buildingId == pd.buildingId;
      final customers = _liveCustomers[pd.buildingId] ?? [];
      final hasCustomers = customers.isNotEmpty;

      // ── Colour logic ──────────────────────────────────────────────────────
      // Blue   = currently selected
      // Green  = has ≥1 customer in ArcGIS Customer Layer
      // Orange = no customers yet (uncaptured)
      final Color fillColor;
      final Color borderColor;

      if (isSelected) {
        fillColor = Colors.blue.withOpacity(0.45);
        borderColor = Colors.blue.shade700;
      } else if (hasCustomers) {
        fillColor = Colors.green.withOpacity(0.30);
        borderColor = Colors.green.shade700;
      } else {
        fillColor = Colors.orange.withOpacity(0.30);
        borderColor = Colors.orange.shade700;
      }

      visiblePolygons.add(Polygon(
        points: pd.points,
        color: fillColor,
        borderColor: borderColor,
        borderStrokeWidth: 2.0,
        isFilled: true,
      ));

      // ── Labels ────────────────────────────────────────────────────────────
      // One chip per customer, stacked vertically on the polygon centroid.
      // Only shown at zoom ≥ _labelZoomThreshold.
      if (hasCustomers && _currentZoom >= _labelZoomThreshold) {
        // Find the BuildingPolygon for the view-only tap
        final buildingPolygon = _livePolygons
            .where((p) => p.buildingId == pd.buildingId)
            .firstOrNull;

        for (int ci = 0; ci < customers.length; ci++) {
          final customer = customers[ci];
          // Show customer/business name if available, else fall back to unit code (R1, C2…)
          final labelText = customer.displayName.isNotEmpty &&
                  customer.displayName != customer.buildingId
              ? customer.displayName
              : (customer.flatNo ?? customer.buildingId);
          if (labelText.isEmpty) continue;

          // Offset each chip slightly downward from the centroid (~5m per chip)
          final offsetLat = pd.center.latitude - (ci * 0.000045);
          final chipPoint = LatLng(offsetLat, pd.center.longitude);

          visibleMarkers.add(Marker(
            point: chipPoint,
            width: 60,
            height: 28,
            child: GestureDetector(
              // Label tap = START PICKUP DIRECTLY for this specific unit
              // (polygon tap = confirmation sheet with all units listed)
              behavior: HitTestBehavior.deferToChild,
              onTap: () {
                if (buildingPolygon != null &&
                    widget.onBuildingSelected != null) {
                  // Enrich the polygon with this customer's data and
                  // start the pickup form immediately
                  final enriched = BuildingPolygon(
                    buildingId: buildingPolygon.buildingId,
                    businessName: customer.businessName,
                    custPhone: customer.custPhone,
                    customerEmail: customer.customerEmail,
                    address: customer.address ?? buildingPolygon.address,
                    zone: buildingPolygon.zone,
                    socioEconomicGroups: buildingPolygon.socioEconomicGroups,
                    geometry: buildingPolygon.geometry,
                    centerLat: buildingPolygon.centerLat,
                    centerLon: buildingPolygon.centerLon,
                    lastUpdated: buildingPolygon.lastUpdated,
                  );
                  widget.onBuildingSelected!(enriched);
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.green.shade700,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: Colors.white, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Center(
                  child: Text(
                    labelText,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      shadows: [
                        Shadow(
                          offset: Offset(1, 1),
                          blurRadius: 2,
                          color: Colors.black,
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
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

  // ─── My Location button ───────────────────────────────────────────────────────

  Future<void> _getCurrentLocation() async {
    try {
      final location = loc.Location();
      final locationData = await location.getLocation();
      if (!mounted) return;

      final currentLoc =
          LatLng(locationData.latitude!, locationData.longitude!);

      setState(() {
        _currentLocation = currentLoc;
        _selectedLocation = currentLoc;
        // Reset viewport tracking so we force a fresh load
        _lastQueriedBounds = null;
      });

      widget.onLocationSelected(
          locationData.latitude!, locationData.longitude!);
      _mapController.move(currentLoc, 18.5);

      // Snap-to-nearest: if a polygon is within 50m, auto-select it
      final nearest =
          _findNearestPolygon(currentLoc, maxDistanceMetres: 50.0);
      if (nearest != null && mounted) {
        setState(() {
          _selectedPolygon = nearest;
          _selectedLocation =
              LatLng(nearest.centerLat, nearest.centerLon);
        });
        widget.onLocationSelected(nearest.centerLat, nearest.centerLon);
        _renderPolygons(useBoundsFilter: _currentBounds != null);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                  'Snapped to nearest building: ${nearest.buildingId}'),
              backgroundColor: Colors.blue.shade700,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }

      // Reload polygons for new location
      await _loadPolygonsNearLocation(currentLoc);
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

  // ─── Tap detection (ray-casting) ─────────────────────────────────────────────

  BuildingPolygon? _findPolygonAtPoint(LatLng tapPoint) {
    for (final pd in _allPolygonData) {
      if (_isPointInPolygon(tapPoint, pd.points)) {
        return _livePolygons
            .where((p) => p.buildingId == pd.buildingId)
            .firstOrNull;
      }
    }
    return null;
  }

  BuildingPolygon? _findNearestPolygon(LatLng point,
      {double maxDistanceMetres = 50.0}) {
    BuildingPolygon? nearest;
    double nearestDist = double.infinity;

    for (final polygon in _livePolygons) {
      final dist = _distanceMetres(
          point.latitude, point.longitude,
          polygon.centerLat, polygon.centerLon);
      if (dist < nearestDist && dist <= maxDistanceMetres) {
        nearestDist = dist;
        nearest = polygon;
      }
    }
    return nearest;
  }

  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    bool inside = false;
    int j = polygon.length - 1;
    for (int i = 0; i < polygon.length; i++) {
      final xi = polygon[i].longitude;
      final yi = polygon[i].latitude;
      final xj = polygon[j].longitude;
      final yj = polygon[j].latitude;
      final intersect =
          ((yi > point.latitude) != (yj > point.latitude)) &&
              (point.longitude <
                  (xj - xi) * (point.latitude - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
      j = i;
    }
    return inside;
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

  // ─── Dialogs ─────────────────────────────────────────────────────────────────

  /// Polygon tap handler — show bottom sheet with building info + customer list.
  void _onPolygonTapped(BuildingPolygon polygon) {
    if (!mounted) return;
    setState(() {
      _selectedPolygon = polygon;
      _selectedLocation = LatLng(polygon.centerLat, polygon.centerLon);
    });
    _renderPolygons(useBoundsFilter: _currentBounds != null);
    widget.onLocationSelected(polygon.centerLat, polygon.centerLon);

    final customers = _liveCustomers[polygon.buildingId] ?? [];
    _showBuildingSheet(polygon, customers);
  }

  /// Show building info bottom sheet.
  /// Lists existing customers and offers "Add New Customer" or "Create Customer".
  void _showBuildingSheet(
      BuildingPolygon polygon, List<CustomerPoint> customers) {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _BuildingSheet(
        polygon: polygon,
        customers: customers,
        onSelectCustomer: (customer) {
          Navigator.pop(ctx);
          // Fill form with existing customer data
          if (widget.onBuildingSelected != null) {
            // Pass a BuildingPolygon enriched with customer data
            final enriched = BuildingPolygon(
              buildingId: polygon.buildingId,
              businessName: customer.businessName,
              custPhone: customer.custPhone,
              customerEmail: customer.customerEmail,
              address: customer.address ?? polygon.address,
              zone: polygon.zone,
              socioEconomicGroups: polygon.socioEconomicGroups,
              geometry: polygon.geometry,
              centerLat: polygon.centerLat,
              centerLon: polygon.centerLon,
              lastUpdated: polygon.lastUpdated,
            );
            widget.onBuildingSelected!(enriched);
          }
        },
        onAddNew: () {
          Navigator.pop(ctx);
          // Fill form with building data only (blank customer fields)
          widget.onBuildingSelected?.call(polygon);
        },
      ),
    );
  }

  /// Label tap — view-only customer list (no form fill).
  void _showCustomersViewOnly(
      BuildingPolygon polygon, List<CustomerPoint> customers) {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.people, color: Colors.green.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Customers at ${polygon.buildingId}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const Divider(),
            if (customers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No customers registered at this building.'),
              )
            else
              // One card per customer with view details + PICKUP button
              ...customers.map((c) => Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    elevation: 0,
                    color: Colors.green.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.green.shade200),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Customer name
                          Row(
                            children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.green.shade100,
                                child: Icon(Icons.person,
                                    color: Colors.green.shade700, size: 18),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  c.displayName,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 15),
                                ),
                              ),
                            ],
                          ),
                          // Phone
                          if (c.custPhone != null && c.custPhone!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6, left: 46),
                              child: Row(
                                children: [
                                  Icon(Icons.phone,
                                      size: 14,
                                      color: Colors.grey.shade600),
                                  const SizedBox(width: 4),
                                  Text(c.custPhone!,
                                      style: TextStyle(
                                          color: Colors.grey.shade700,
                                          fontSize: 13)),
                                ],
                              ),
                            ),
                          // Email
                          if (c.customerEmail != null &&
                              c.customerEmail!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4, left: 46),
                              child: Row(
                                children: [
                                  Icon(Icons.email,
                                      size: 14,
                                      color: Colors.grey.shade600),
                                  const SizedBox(width: 4),
                                  Text(c.customerEmail!,
                                      style: TextStyle(
                                          color: Colors.grey.shade700,
                                          fontSize: 13)),
                                ],
                              ),
                            ),
                          // Address
                          if (c.address != null && c.address!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4, left: 46),
                              child: Row(
                                children: [
                                  Icon(Icons.location_on,
                                      size: 14,
                                      color: Colors.grey.shade600),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(c.address!,
                                        style: TextStyle(
                                            color: Colors.grey.shade700,
                                            fontSize: 13)),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 10),
                          // PICKUP button
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.local_shipping, size: 16),
                              label: const Text('PICKUP'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 10),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              onPressed: () {
                                Navigator.pop(ctx);
                                // Fill form with this customer's data
                                if (widget.onBuildingSelected != null) {
                                  final enriched = BuildingPolygon(
                                    buildingId: polygon.buildingId,
                                    businessName: c.businessName,
                                    custPhone: c.custPhone,
                                    customerEmail: c.customerEmail,
                                    address:
                                        c.address ?? polygon.address,
                                    zone: polygon.zone,
                                    socioEconomicGroups:
                                        polygon.socioEconomicGroups,
                                    geometry: polygon.geometry,
                                    centerLat: polygon.centerLat,
                                    centerLon: polygon.centerLon,
                                    lastUpdated: polygon.lastUpdated,
                                  );
                                  widget.onBuildingSelected!(enriched);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  )),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_phase == _LoadPhase.error) {
      return _ErrorView(
        message: _errorText ?? 'An error occurred',
        onRetry: _startLocate,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Status banner
        if (_phase != _LoadPhase.ready && _phase != _LoadPhase.idle)
          _StatusBanner(phase: _phase, text: _statusText),

        // Info chip
        _InfoChip(
          polygonCount: _livePolygons.length,
          customerCount: _liveCustomers.values
              .fold(0, (s, l) => s + l.length),
          overlayCount: _visiblePolygons.length,
          onRefresh: _getCurrentLocation,
        ),

        // Map — fixed 400px height
        Container(
          height: 400,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentLocation ??
                    LatLng(
                      widget.initialLat ?? 6.5244,
                      widget.initialLon ?? 3.3792,
                    ),
                initialZoom: 18.5,
                onTap: (tapPosition, latlng) {
                  if (!mounted) return;
                  final polygon = _findPolygonAtPoint(latlng);
                  if (polygon != null) {
                    _onPolygonTapped(polygon);
                    return;
                  }
                  setState(() {
                    _selectedLocation = latlng;
                    _selectedPolygon = null;
                  });
                  widget.onLocationSelected(
                      latlng.latitude, latlng.longitude);
                },
                onMapReady: () {
                  _mapReady = true;
                  // Move to GPS location if available — covers the race where
                  // GPS arrived before the map was ready.
                  final target = _pendingCenter ?? _currentLocation;
                  if (target != null) {
                    _mapController.move(target, 18.5);
                    _pendingCenter = null;
                  }
                  if (_allPolygonData.isNotEmpty) {
                    _renderPolygons(useBoundsFilter: false);
                  }
                },
                onPositionChanged: (camera, hasGesture) {
                  _currentBounds = camera.visibleBounds;
                  _currentZoom = camera.zoom;

                  // Only re-cull on user gestures — programmatic moves (GPS
                  // centering, onMapReady) must NOT trigger a culling pass
                  // because they run before the initial render completes and
                  // would wipe _visiblePolygons back to empty.
                  if (hasGesture && _allPolygonData.isNotEmpty) {
                    _cullingDebounce?.cancel();
                    _cullingDebounce = Timer(
                      const Duration(milliseconds: 250),
                      () => _renderPolygons(useBoundsFilter: true),
                    );
                  }

                  // Query ArcGIS for new viewport (debounced, only on user gesture)
                  if (hasGesture && _phase == _LoadPhase.ready) {
                    _viewportDebounce?.cancel();
                    _viewportDebounce = Timer(
                      const Duration(milliseconds: 800),
                      () {
                        if (_currentBounds != null) {
                          _loadPolygonsForViewport(_currentBounds!);
                        }
                      },
                    );
                  }
                },
              ),
              children: <Widget>[
                // Satellite imagery
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services'
                      '/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.mottainai.mottainai_survey',
                  maxZoom: 19,
                  panBuffer: 0,
                ),
                // Street names + place labels overlay
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services'
                      '/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.mottainai.mottainai_survey',
                  maxZoom: 19,
                  panBuffer: 0,
                ),
                // Building polygon outlines
                PolygonLayer(polygons: _visiblePolygons),
                // Customer name label chips
                MarkerLayer(markers: _visibleMarkers),
                // Selected location pin
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
                // Current location dot
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
              ],
            ),
          ),
        ),

        // Bottom controls
        _MapControls(
          onMyLocation: _getCurrentLocation,
          onRefreshOverlays: () {
            // Force a nudge: move map by a tiny amount and back to trigger
            // onPositionChanged with hasGesture=false, then re-render.
            if (_mapReady && _currentLocation != null) {
              final loc = _currentLocation!;
              _mapController.move(
                  LatLng(loc.latitude + 0.000001, loc.longitude), _currentZoom);
              Future.delayed(const Duration(milliseconds: 100), () {
                if (mounted) {
                  _mapController.move(loc, _currentZoom);
                  Future.delayed(const Duration(milliseconds: 150), () {
                    if (mounted) _renderPolygons(useBoundsFilter: false);
                  });
                }
              });
            } else {
              _renderPolygons(useBoundsFilter: false);
            }
          },
          isLoading: _phase == _LoadPhase.loading,
          polygonCount: _livePolygons.length,
          overlayCount: _visiblePolygons.length,
        ),
      ],
    );
  }
}

// ─── Sub-widgets ──────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final _LoadPhase phase;
  final String text;

  const _StatusBanner({required this.phase, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: Colors.blue.shade50,
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style:
                  TextStyle(fontSize: 12, color: Colors.blue.shade700),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final int polygonCount;
  final int customerCount;
  final int overlayCount;
  final VoidCallback onRefresh;

  const _InfoChip({
    required this.polygonCount,
    required this.customerCount,
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
          BoxShadow(
              color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.domain, color: Colors.green.shade700, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$polygonCount buildings • $customerCount customers'
              ' | overlays:$overlayCount',
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
  final VoidCallback onRefreshOverlays;
  final bool isLoading;
  final int polygonCount;
  final int overlayCount;

  const _MapControls({
    required this.onMyLocation,
    required this.onRefreshOverlays,
    required this.isLoading,
    required this.polygonCount,
    required this.overlayCount,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            isLoading ? 'Loading...' : '$polygonCount buildings loaded',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Show overlays button — visible when polygons are loaded but
              // overlays are not rendering (overlayCount == 0 && polygonCount > 0)
              if (!isLoading && polygonCount > 0 && overlayCount == 0)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ElevatedButton.icon(
                    onPressed: onRefreshOverlays,
                    icon: const Icon(Icons.layers, size: 18),
                    label: const Text('Show Overlays'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange.shade700,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
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
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade400, size: 40),
          const SizedBox(height: 8),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ─── Building info bottom sheet ───────────────────────────────────────────────

class _BuildingSheet extends StatelessWidget {
  final BuildingPolygon polygon;
  final List<CustomerPoint> customers;
  final void Function(CustomerPoint customer) onSelectCustomer;
  final VoidCallback onAddNew;

  const _BuildingSheet({
    required this.polygon,
    required this.customers,
    required this.onSelectCustomer,
    required this.onAddNew,
  });

  @override
  Widget build(BuildContext context) {
    final address = polygon.address ??
        polygon.businessName ??
        polygon.zone ??
        '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
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

          // Building header
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(12),
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
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (address.isNotEmpty)
                      Text(address,
                          style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600)),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),
          const Divider(),

          // Customer count summary
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.people_outline,
                    size: 16, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Text(
                  customers.isEmpty
                      ? 'No customers yet'
                      : '${customers.length} customer${customers.length == 1 ? '' : 's'} registered',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),

          // Existing customer list
          if (customers.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...customers.map((c) => Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Colors.green.shade100,
                      child: Icon(Icons.person,
                          color: Colors.green.shade700, size: 18),
                    ),
                    title: Text(c.displayName,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600)),
                    subtitle: c.custPhone != null
                        ? Text(c.custPhone!)
                        : null,
                    trailing: TextButton(
                      onPressed: () => onSelectCustomer(c),
                      child: const Text('SELECT'),
                    ),
                    dense: true,
                  ),
                )),
            const SizedBox(height: 8),
          ],

          const SizedBox(height: 8),

          // Add New Customer button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onAddNew,
              icon: const Icon(Icons.add),
              label: Text(customers.isEmpty
                  ? 'CREATE CUSTOMER'
                  : 'ADD NEW CUSTOMER'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
