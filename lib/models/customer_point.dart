/// Represents a single customer point from the ArcGIS Customer Layer.
/// Each CustomerPoint is spatially associated with a building polygon
/// via the [buildingId] foreign key.
///
/// The composite key is [buildingId] + [flatNo] (unit code, e.g. R1, C2).
/// One CustomerPoint exists per unit — never one per polygon.
class CustomerPoint {
  final int? objectId;
  final String buildingId;

  /// Unit code assigned to this customer (e.g. R1, R2, C1, C2).
  /// Stored in the ArcGIS `flat_no` field.
  final String? flatNo;

  final String? businessName;
  final String? firstName;
  final String? lastName;
  final String? custPhone;
  final String? customerEmail;
  final String? customerType;
  final String? status;
  final String? address;
  final double? lat;
  final double? lon;
  /// GIS Integration Step 2.2: MCU-XXXXXX customer identity.
  /// Read from ArcGIS Customer Layer `user_identification_number` field.
  final String? userIdentificationNumber;

  const CustomerPoint({
    this.objectId,
    required this.buildingId,
    this.flatNo,
    this.businessName,
    this.firstName,
    this.lastName,
    this.custPhone,
    this.customerEmail,
    this.customerType,
    this.status,
    this.address,
    this.lat,
    this.lon,
    this.userIdentificationNumber,
  });

  /// The primary label shown on the map chip.
  /// Prefers the unit code (R1, C2) so the map stays clean and unambiguous.
  /// Falls back to business_name → "first last" → buildingId.
  String get chipLabel {
    if (flatNo != null && flatNo!.trim().isNotEmpty) return flatNo!.trim();
    return displayName;
  }

  /// The full customer name for display in lists and sheets.
  /// Prefers business_name; falls back to "first last"; falls back to buildingId.
  /// Filters out known placeholder values ("esteemed customer", "None", etc.).
  String get displayName {
    bool isValid(String? s) {
      if (s == null || s.trim().isEmpty) return false;
      const placeholders = {
        'esteemed customer', 'none', 'null', 'n/a', 'na', 'unknown', '-'
      };
      return !placeholders.contains(s.trim().toLowerCase());
    }
    if (isValid(businessName)) return businessName!.trim();
    final first = firstName?.trim() ?? '';
    final last = lastName?.trim() ?? '';
    final full = '$first $last'.trim();
    if (isValid(full)) return full;
    return buildingId;
  }

  /// Parse a feature from the ArcGIS Customer Layer query response.
  factory CustomerPoint.fromArcGIS(Map<String, dynamic> feature) {
    final attrs = feature['attributes'] as Map<String, dynamic>? ?? {};

    // Geometry is a point — may be null if the record has no geometry
    double? lat, lon;
    final geom = feature['geometry'];
    if (geom != null) {
      // ArcGIS returns {x: lon, y: lat} for points when outSR=4326
      final x = geom['x'];
      final y = geom['y'];
      if (x != null && y != null) {
        lon = (x as num).toDouble();
        lat = (y as num).toDouble();
      }
    }

    // Also check the explicit Lat/Long attribute fields as fallback
    lat ??= _toDouble(attrs['Lat']);
    lon ??= _toDouble(attrs['Long']);

    return CustomerPoint(
      objectId: attrs['OBJECTID'] as int?,
      buildingId: attrs['building_id']?.toString() ?? '',
      flatNo: _nullIfEmpty(attrs['flat_no']?.toString()),
      businessName: _nullIfEmpty(attrs['business_name']?.toString()),
      firstName: _nullIfEmpty(attrs['first_name']?.toString()),
      lastName: _nullIfEmpty(attrs['last_name']?.toString()),
      custPhone: _nullIfEmpty(attrs['cust_phone']?.toString()),
      customerEmail: _nullIfEmpty(attrs['customer_email']?.toString()),
      customerType: _nullIfEmpty(attrs['customer_type']?.toString()),
      status: _nullIfEmpty(attrs['status']?.toString()),
      address: _nullIfEmpty(attrs['address2']?.toString()),
      lat: lat,
      lon: lon,
      userIdentificationNumber: _nullIfEmpty(attrs['user_identification_number']?.toString()),
    );
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static String? _nullIfEmpty(String? s) =>
      (s == null || s.trim().isEmpty || s == 'null') ? null : s.trim();

  /// Convert to ArcGIS addFeatures / updateFeatures attributes map.
  Map<String, dynamic> toArcGISAttributes() {
    return {
      'building_id': buildingId,
      if (flatNo != null) 'flat_no': flatNo,
      if (businessName != null) 'business_name': businessName,
      if (firstName != null) 'first_name': firstName,
      if (lastName != null) 'last_name': lastName,
      if (custPhone != null) 'cust_phone': custPhone,
      if (customerEmail != null) 'customer_email': customerEmail,
      if (customerType != null) 'customer_type': customerType,
      if (address != null) 'address2': address,
      if (lat != null) 'Lat': lat,
      if (lon != null) 'Long': lon,
      if (userIdentificationNumber != null) 'user_identification_number': userIdentificationNumber,
    };
  }
}
