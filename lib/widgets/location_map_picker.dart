import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;
import 'package:url_launcher/url_launcher.dart';

class LocationMapPicker extends StatefulWidget {
  final Function(double lat, double lon) onLocationSelected;
  final double? initialLat;
  final double? initialLon;

  const LocationMapPicker({
    super.key,
    required this.onLocationSelected,
    this.initialLat,
    this.initialLon,
  });

  @override
  State<LocationMapPicker> createState() => _LocationMapPickerState();
}

class _LocationMapPickerState extends State<LocationMapPicker> {
  final MapController _mapController = MapController();
  LatLng? _selectedLocation;
  LatLng? _currentLocation;
  bool _isLoading = true;
  String? _error;

  // ArcGIS API Key (reserved for future use)
  // ignore: unused_field
  final String _arcgisApiKey = 'AAPTxy8BH1VEsoebNVZXo8HurDkT4HeplNOm_pLCsV2-wHXD7esJFqWCGo3oDxTaOVO68fIzhjQ4gSKqccl-uynuHunhlN5t3E_x5N010mOKYQRyFm3vYXqvila3dJ3Ax81DMK2WyxFt6mqhwzxdkdhmm7USv7-cQi07L_22-MTRC95Rns1BHueP3kR_yXyAyh1WEFAm9Q7KFELPkRpT_5cjWvbDo2rWZhtHOb5xFr_7bOA.AT1_n5wNkDcc';

  @override
  void initState() {
    super.initState();
    _initializeLocation();
  }

  Future<void> _initializeLocation() async {
    try {
      loc.Location location = loc.Location();

      // Check if location services are enabled
      bool serviceEnabled = await location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await location.requestService();
        if (!serviceEnabled) {
          setState(() {
            _error = 'Location services are disabled. Please enable them.';
            _isLoading = false;
          });
          return;
        }
      }

      // Check location permissions
      loc.PermissionStatus permissionGranted = await location.hasPermission();
      if (permissionGranted == loc.PermissionStatus.denied) {
        permissionGranted = await location.requestPermission();
        if (permissionGranted != loc.PermissionStatus.granted) {
          setState(() {
            _error = 'Location permission denied';
            _isLoading = false;
          });
          return;
        }
      }

      // Get current location
      loc.LocationData locationData = await location.getLocation();

      setState(() {
        _currentLocation = LatLng(locationData.latitude!, locationData.longitude!);
        
        // Use initial location if provided, otherwise use current location
        if (widget.initialLat != null && widget.initialLon != null) {
          _selectedLocation = LatLng(widget.initialLat!, widget.initialLon!);
        } else {
          _selectedLocation = _currentLocation;
          widget.onLocationSelected(locationData.latitude!, locationData.longitude!);
        }
        
        _isLoading = false;
      });

      // Move map to location after first frame
      if (_selectedLocation != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _mapController.move(_selectedLocation!, 15.0);
          }
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to get location: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _getCurrentLocation() async {
    try {
      loc.Location location = loc.Location();
      loc.LocationData locationData = await location.getLocation();

      setState(() {
        _currentLocation = LatLng(locationData.latitude!, locationData.longitude!);
        _selectedLocation = _currentLocation;
      });

      widget.onLocationSelected(locationData.latitude!, locationData.longitude!);
      
      // Safely move map after ensuring it's rendered
      if (mounted) {
        _mapController.move(_currentLocation!, 15.0);
      }
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

  Future<void> _openStreetView() async {
    if (_selectedLocation == null) return;

    final lat = _selectedLocation!.latitude;
    final lon = _selectedLocation!.longitude;
    
    // Google Maps Street View URL
    final url = Uri.parse('https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=$lat,$lon');
    
    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not open Street View'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error opening Street View: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _onMapTap(TapPosition tapPosition, LatLng position) {
    setState(() {
      _selectedLocation = position;
    });
    widget.onLocationSelected(position.latitude, position.longitude);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        height: 300,
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
        height: 300,
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
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
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
          height: 300,
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
                    initialCenter: _selectedLocation ?? const LatLng(6.5795, 3.3549),
                    initialZoom: 15.0,
                    onTap: _onMapTap,
                  ),
                  children: [
                    TileLayer(
                      // Using ArcGIS World Imagery (Satellite) basemap
                      urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.mottainai.survey',
                      maxZoom: 19,
                    ),
                    TileLayer(
                      // Labels overlay
                      urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
                      userAgentPackageName: 'com.mottainai.survey',
                      maxZoom: 19,
                    ),
                    if (_selectedLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _selectedLocation!,
                            width: 40,
                            height: 40,
                            child: const Icon(
                              Icons.location_pin,
                              color: Colors.red,
                              size: 40,
                            ),
                          ),
                        ],
                      ),
                    if (_currentLocation != null && _currentLocation != _selectedLocation)
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
                                border: Border.all(color: Colors.blue, width: 2),
                              ),
                              child: const Icon(
                                Icons.my_location,
                                color: Colors.blue,
                                size: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                // Current location button
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
                // Street View button
                if (_selectedLocation != null)
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: FloatingActionButton(
                      mini: true,
                      onPressed: _openStreetView,
                      backgroundColor: Colors.white,
                      child: const Icon(Icons.streetview, color: Colors.orange),
                    ),
                  ),
                // Instructions overlay
                Positioned(
                  top: 10,
                  left: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Press to set location',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (_selectedLocation != null)
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
