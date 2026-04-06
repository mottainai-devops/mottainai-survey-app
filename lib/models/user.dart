class User {
  final String id;
  final String email;
  final String fullName;
  final String phone;
  final String role;
  final bool monthlyBilling;
  final String? companyId;
  final String? companyName;

  User({
    required this.id,
    required this.email,
    required this.fullName,
    required this.phone,
    required this.role,
    required this.monthlyBilling,
    this.companyId,
    this.companyName,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      email: (json['email'] as String?) ?? '',
      fullName: (json['fullName'] as String?) ?? '',
      phone: (json['phone'] as String?) ?? '',
      role: (json['role'] as String?) ?? 'user',
      monthlyBilling: json['monthlyBilling'] as bool? ?? false,
      companyId: json['companyId'] as String?,
      companyName: json['companyName'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'email': email,
      'fullName': fullName,
      'phone': phone,
      'role': role,
      'monthlyBilling': monthlyBilling,
      'companyId': companyId,
      'companyName': companyName,
    };
  }
}
