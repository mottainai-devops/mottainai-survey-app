import 'dart:convert';

class BuildingPolygon {
  final String buildingId;
  final String? businessName;
  final String? custPhone;
  final String? customerEmail;
  final String? address;
  final String? zone;
  final String? socioEconomicGroups;
  final String geometry; // GeoJSON polygon (WGS84)
  final double centerLat;
  final double centerLon;
  final DateTime lastUpdated;
  final String? customerLabels; // e.g., "R1,R2,B1"
  /// When an existing customer is selected from the building sheet, this holds
  /// their unit code (flat_no, e.g. R1, C2). If set, the submit flow should
  /// reuse this code instead of generating a new one via getNextUnitCode().
  final String? selectedFlatNo;

  BuildingPolygon({
    required this.buildingId,
    this.businessName,
    this.custPhone,
    this.customerEmail,
    this.address,
    this.zone,
    this.socioEconomicGroups,
    required this.geometry,
    required this.centerLat,
    required this.centerLon,
    required this.lastUpdated,
    this.customerLabels,
    this.selectedFlatNo,
  });

  /// Parse an ArcGIS Feature Service response feature.
  ///
  /// IMPORTANT: The ArcGIS query MUST include `outSR=4326` so the server
  /// returns coordinates in WGS84 (lon, lat). Without outSR=4326 the service
  /// returns a local Nigerian projection whose values look like (432303, 821170)
  /// — those are NOT standard Web Mercator and the old conversion formula
  /// placed polygons ~80km away from the actual buildings.
  factory BuildingPolygon.fromArcGIS(Map<String, dynamic> feature) {
    final attributes = feature['attributes'] as Map<String, dynamic>;
    final geometry = feature['geometry'] as Map<String, dynamic>;

    // Coordinates are already WGS84 (lon, lat) because we pass outSR=4326
    final rings = geometry['rings'] as List;

    double sumLat = 0, sumLon = 0;
    int count = 0;
    List<List<List<double>>> wgs84Rings = [];

    for (var ring in rings) {
      final ringList = ring as List;
      List<List<double>> wgs84Ring = [];
      for (var point in ringList) {
        if (point is List && point.length >= 2) {
          // ArcGIS returns [lon, lat] when outSR=4326
          final lon = (point[0] is int)
              ? (point[0] as int).toDouble()
              : point[0] as double;
          final lat = (point[1] is int)
              ? (point[1] as int).toDouble()
              : point[1] as double;
          wgs84Ring.add([lon, lat]);
          sumLon += lon;
          sumLat += lat;
          count++;
        }
      }
      if (wgs84Ring.isNotEmpty) {
        wgs84Rings.add(wgs84Ring);
      }
    }

    final centerLon = count > 0 ? sumLon / count : 0.0;
    final centerLat = count > 0 ? sumLat / count : 0.0;

    final wgs84Geometry = {
      'rings': wgs84Rings,
      'spatialReference': {'wkid': 4326},
    };

    return BuildingPolygon(
      buildingId: attributes['building_id']?.toString() ?? '',
      // business_name, cust_phone, customer_email are not in the new
      // Nigeria_Building_Footprints layer — they come from the Customer Layer
      // and are populated separately via fetchCustomerPointsForBuilding().
      businessName: null,
      custPhone: null,
      customerEmail: null,
      address: attributes['address']?.toString(),
      // Zone and socio_economic_groups were removed from the new footprint
      // layer (2026-04-07). They remain in the Customer Layer and are read
      // via getSocioEconomicClass() when a building is selected on the map.
      zone: null,
      socioEconomicGroups: null,
      geometry: jsonEncode(wgs84Geometry),
      centerLat: centerLat,
      centerLon: centerLon,
      lastUpdated: DateTime.now(),
    );
  }

  // To SQLite database
  Map<String, dynamic> toMap() {
    return {
      'buildingId': buildingId,
      'businessName': businessName,
      'custPhone': custPhone,
      'customerEmail': customerEmail,
      'address': address,
      'zone': zone,
      'socioEconomicGroups': socioEconomicGroups,
      'geometry': geometry,
      'centerLat': centerLat,
      'centerLon': centerLon,
      'lastUpdated': lastUpdated.millisecondsSinceEpoch,
      'customerLabels': customerLabels,
    };
  }

  // From SQLite database
  factory BuildingPolygon.fromMap(Map<String, dynamic> map) {
    return BuildingPolygon(
      buildingId: map['buildingId'] as String,
      businessName: map['businessName'] as String?,
      custPhone: map['custPhone'] as String?,
      customerEmail: map['customerEmail'] as String?,
      address: map['address'] as String?,
      zone: map['zone'] as String?,
      socioEconomicGroups: map['socioEconomicGroups'] as String?,
      geometry: map['geometry'] as String,
      centerLat: map['centerLat'] as double,
      centerLon: map['centerLon'] as double,
      lastUpdated:
          DateTime.fromMillisecondsSinceEpoch(map['lastUpdated'] as int),
      customerLabels: map['customerLabels'] as String?,
    );
  }
}
