import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/company.dart';

class CompanyService {
  static const String _baseUrl = 'https://upwork.kowope.xyz';
  static const String _cacheKey = 'cached_companies';
  static const String _cacheTimestampKey = 'companies_cache_timestamp';
  
  /// Fetch active companies from API
  Future<List<Company>> fetchActiveCompanies() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/companies/active'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final companies = (data['companies'] as List<dynamic>)
            .map((json) => Company.fromJson(json as Map<String, dynamic>))
            .toList();

        // Cache the companies locally
        await _cacheCompanies(companies);

        return companies;
      } else {
        throw Exception('Failed to fetch companies: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching companies: $e');
      // Try to load from cache if API fails
      return await getCachedCompanies();
    }
  }

  /// Get companies from local cache
  Future<List<Company>> getCachedCompanies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString(_cacheKey);
      
      if (cachedData == null) {
        return [];
      }

      final List<dynamic> jsonList = jsonDecode(cachedData);
      return jsonList
          .map((json) => Company.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print('Error loading cached companies: $e');
      return [];
    }
  }

  /// Cache companies locally
  Future<void> _cacheCompanies(List<Company> companies) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = companies.map((c) => c.toJson()).toList();
      await prefs.setString(_cacheKey, jsonEncode(jsonList));
      await prefs.setInt(_cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      print('Error caching companies: $e');
    }
  }

  /// Check if cache needs refresh (older than 24 hours)
  Future<bool> needsRefresh() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = prefs.getInt(_cacheTimestampKey);
      
      if (timestamp == null) return true;
      
      final cacheDate = DateTime.fromMillisecondsSinceEpoch(timestamp);
      final hoursSinceCache = DateTime.now().difference(cacheDate).inHours;
      
      return hoursSinceCache > 1; // Refresh every hour to get latest webhook URLs
    } catch (e) {
      return true;
    }
  }

  /// Get companies with automatic cache/refresh logic
  Future<List<Company>> getCompanies({bool forceRefresh = false}) async {
    try {
      // If force refresh or cache needs refresh, fetch from API
      if (forceRefresh || await needsRefresh()) {
        return await fetchActiveCompanies();
      }
      
      // Otherwise, try cache first
      final cached = await getCachedCompanies();
      if (cached.isNotEmpty) {
        return cached;
      }
      
      // If cache is empty, fetch from API
      return await fetchActiveCompanies();
    } catch (e) {
      print('Error getting companies: $e');
      return [];
    }
  }

  /// Get webhook URL for a specific company, lot, and customer type
  String getWebhookUrl({
    required Company company,
    required OperationalLot lot,
    required String customerType, // 'PAYT' or 'Monthly Billing'
  }) {
    if (customerType == 'PAYT') {
      return lot.paytWebhook;
    } else {
      return lot.monthlyWebhook;
    }
  }

  /// Find company by ID
  Future<Company?> getCompanyById(String companyId) async {
    final companies = await getCompanies();
    try {
      return companies.firstWhere((c) => c.companyId == companyId);
    } catch (e) {
      return null;
    }
  }

  /// Find operational lot in a company
  OperationalLot? findLot(Company company, String lotCode) {
    try {
      return company.operationalLots.firstWhere((lot) => lot.lotCode == lotCode);
    } catch (e) {
      return null;
    }
  }

  /// Validate PIN and return company if valid
  Future<Company?> validatePin(String pin) async {
    try {
      final companies = await getCompanies();
      return companies.firstWhere(
        (c) => c.pinCode == pin && c.isActive,
        orElse: () => throw Exception('Invalid PIN'),
      );
    } catch (e) {
      print('PIN validation failed: $e');
      return null;
    }
  }

  /// Clear company cache
  Future<void> clearCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
      await prefs.remove(_cacheTimestampKey);
    } catch (e) {
      print('Error clearing company cache: $e');
    }
  }
}
