class PickupSubmission {
  final int? id;
  final String formId;
  final String supervisorId;
  // Customer contact fields (added v3.2.5)
  final String customerName;
  final String customerPhone;
  final String customerEmail;
  final String customerAddress;
  final String customerType;
  final String binType;
  final String? wheelieBinType;
  final int binQuantity;
  final String buildingId;
  final String pickUpDate;
  final String firstPhoto;
  final String secondPhoto;
  final String? incidentReport;
  final String userId;
  final double? latitude;
  final double? longitude;
  final int synced;
  final String createdAt;
  final String? companyId;
  final String? companyName;
  final String? lotCode;
  final String? lotName;
  final String? socioClass;
  // ArcGIS Footprint Polygon building_id (e.g. "8038 LASIKA06 006") — added v3.3.0
  final String? arcgisBuildingId;

  PickupSubmission({
    this.id,
    required this.formId,
    required this.supervisorId,
    this.customerName = '',
    this.customerPhone = '',
    this.customerEmail = '',
    this.customerAddress = '',
    required this.customerType,
    required this.binType,
    this.wheelieBinType,
    required this.binQuantity,
    required this.buildingId,
    required this.pickUpDate,
    required this.firstPhoto,
    required this.secondPhoto,
    this.incidentReport,
    required this.userId,
    this.latitude,
    this.longitude,
    this.synced = 0,
    required this.createdAt,
    this.companyId,
    this.companyName,
    this.lotCode,
    this.lotName,
    this.socioClass,
    this.arcgisBuildingId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'formId': formId,
      'supervisorId': supervisorId,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'customerEmail': customerEmail,
      'customerAddress': customerAddress,
      'customerType': customerType,
      'binType': binType,
      'wheelieBinType': wheelieBinType,
      'binQuantity': binQuantity,
      'buildingId': buildingId,
      'pickUpDate': pickUpDate,
      'firstPhoto': firstPhoto,
      'secondPhoto': secondPhoto,
      'incidentReport': incidentReport,
      'userId': userId,
      'latitude': latitude,
      'longitude': longitude,
      'synced': synced,
      'createdAt': createdAt,
      'companyId': companyId,
      'companyName': companyName,
      'lotCode': lotCode,
      'lotName': lotName,
      'socioClass': socioClass,
      'arcgisBuildingId': arcgisBuildingId,
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'formId': formId,
      'supervisorId': supervisorId,
      'customerName': customerName,
      'customerPhone': customerPhone,
      'customerEmail': customerEmail,
      'customerAddress': customerAddress,
      'customerType': customerType,
      'binType': binType,
      'wheelieBinType': wheelieBinType,
      'binQuantity': binQuantity,
      'buildingId': buildingId,
      'pickUpDate': pickUpDate,
      'firstPhoto': firstPhoto,
      'secondPhoto': secondPhoto,
      'incidentReport': incidentReport,
      'userId': userId,
      'latitude': latitude,
      'longitude': longitude,
      'companyId': companyId,
      'companyName': companyName,
      'lotCode': lotCode,
      'lotName': lotName,
      'socioClass': socioClass,
      'arcgisBuildingId': arcgisBuildingId,
    };
  }

  factory PickupSubmission.fromMap(Map<String, dynamic> map) {
    return PickupSubmission(
      id: map['id'] as int?,
      formId: map['formId'] as String,
      supervisorId: map['supervisorId'] as String,
      customerName: map['customerName'] as String? ?? '',
      customerPhone: map['customerPhone'] as String? ?? '',
      customerEmail: map['customerEmail'] as String? ?? '',
      customerAddress: map['customerAddress'] as String? ?? '',
      customerType: map['customerType'] as String,
      binType: map['binType'] as String,
      wheelieBinType: map['wheelieBinType'] as String?,
      binQuantity: map['binQuantity'] as int,
      buildingId: map['buildingId'] as String,
      pickUpDate: map['pickUpDate'] as String,
      firstPhoto: map['firstPhoto'] as String,
      secondPhoto: map['secondPhoto'] as String,
      incidentReport: map['incidentReport'] as String?,
      userId: map['userId'] as String,
      latitude: map['latitude'] as double?,
      longitude: map['longitude'] as double?,
      synced: map['synced'] as int? ?? 0,
      createdAt: map['createdAt'] as String,
      companyId: map['companyId'] as String?,
      companyName: map['companyName'] as String?,
      lotCode: map['lotCode'] as String?,
      lotName: map['lotName'] as String?,
      socioClass: map['socioClass'] as String?,
      arcgisBuildingId: map['arcgisBuildingId'] as String?,
    );
  }

  PickupSubmission copyWith({
    int? id,
    String? formId,
    String? supervisorId,
    String? customerName,
    String? customerPhone,
    String? customerEmail,
    String? customerAddress,
    String? customerType,
    String? binType,
    String? wheelieBinType,
    int? binQuantity,
    String? buildingId,
    String? pickUpDate,
    String? firstPhoto,
    String? secondPhoto,
    String? incidentReport,
    String? userId,
    double? latitude,
    double? longitude,
    int? synced,
    String? createdAt,
    String? companyId,
    String? companyName,
    String? lotCode,
    String? lotName,
    String? socioClass,
    String? arcgisBuildingId,
  }) {
    return PickupSubmission(
      id: id ?? this.id,
      formId: formId ?? this.formId,
      supervisorId: supervisorId ?? this.supervisorId,
      customerName: customerName ?? this.customerName,
      customerPhone: customerPhone ?? this.customerPhone,
      customerEmail: customerEmail ?? this.customerEmail,
      customerAddress: customerAddress ?? this.customerAddress,
      customerType: customerType ?? this.customerType,
      binType: binType ?? this.binType,
      wheelieBinType: wheelieBinType ?? this.wheelieBinType,
      binQuantity: binQuantity ?? this.binQuantity,
      buildingId: buildingId ?? this.buildingId,
      pickUpDate: pickUpDate ?? this.pickUpDate,
      firstPhoto: firstPhoto ?? this.firstPhoto,
      secondPhoto: secondPhoto ?? this.secondPhoto,
      incidentReport: incidentReport ?? this.incidentReport,
      userId: userId ?? this.userId,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      synced: synced ?? this.synced,
      createdAt: createdAt ?? this.createdAt,
      companyId: companyId ?? this.companyId,
      companyName: companyName ?? this.companyName,
      lotCode: lotCode ?? this.lotCode,
      lotName: lotName ?? this.lotName,
      socioClass: socioClass ?? this.socioClass,
      arcgisBuildingId: arcgisBuildingId ?? this.arcgisBuildingId,
    );
  }
}
