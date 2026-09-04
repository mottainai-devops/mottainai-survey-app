import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/company.dart';

class LotService {
  static const String _apiUrl = 'https://admin.kowope.xyz/api/trpc/lots.list';
  static const String _validateUrl = 'https://admin.kowope.xyz/api/trpc/lots.validateAccess';
  static const String _cacheKey = 'cached_lots';
  static const String _cacheTimestampKey = 'cached_lots_timestamp';
  static const String _cacheUserIdKey = 'cached_lots_user_id';
  static const String _cacheVersionKey = 'cached_lots_version';
  static const String _cacheVersion = '2';
  static const Duration _cacheExpiry = Duration(hours: 24);

  final http.Client _client;
  LotService({http.Client? client}) : _client = client ?? http.Client();

  Map<String, String> _authorizedHeaders(String token) {
    if (token.trim().isEmpty) {
      throw LotAccessUnauthorizedException('Please sign in again to load operational lots.');
    }
    return {'Content-Type': 'application/json', 'Authorization': 'Bearer ${token.trim()}'};
  }

  Future<void> _ensureCacheVersion() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_cacheVersionKey) == _cacheVersion) return;
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimestampKey);
    await prefs.remove(_cacheUserIdKey);
    await prefs.setString(_cacheVersionKey, _cacheVersion);
  }

  /// Fetches only the lots authorized for the verified Survey JWT. userId is
  /// retained strictly as a local cache namespace and is never sent to tRPC.
  Future<List<OperationalLot>> fetchLots(String userId, {required String token}) async {
    try {
      final inputData = {'0': {'json': <String, dynamic>{}}};
      final encodedInput = Uri.encodeComponent(json.encode(inputData));
      final response = await _client
          .get(Uri.parse('$_apiUrl?batch=1&input=$encodedInput'), headers: _authorizedHeaders(token))
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 401 || response.statusCode == 403) {
        await clearCache();
        throw LotAccessUnauthorizedException('Your Survey session has expired. Please sign in again.');
      }
      if (response.statusCode != 200) {
        throw Exception('Failed to load lots: ${response.statusCode}');
      }

      final data = json.decode(response.body);
      final result = data[0]['result']['data']['json'];
      final lotsJson = result['lots'] as List;
      final lots = lotsJson.map((lot) => OperationalLot(
        lotCode: lot['lotCode'] ?? '',
        lotName: lot['lotName'] ?? '',
        paytWebhook: lot['paytWebhook'] ?? '',
        monthlyWebhook: lot['monthlyWebhook'] ?? '',
        companyId: lot['companyId'] ?? '',
        companyName: lot['companyName'] ?? '',
      )).toList();
      await _cacheLots(userId, lots);
      return lots;
    } on LotAccessUnauthorizedException {
      rethrow;
    } catch (error) {
      // Legacy cache must never mask an authorization failure or preserve a
      // cross-scope payload after this access-control upgrade.
      final cachedLots = await _getCachedLots(userId, ignoreExpiry: true);
      if (cachedLots.isNotEmpty) return cachedLots;
      rethrow;
    }
  }

  Future<bool> validateLotAccess({
    required String lotCode,
    required String companyId,
    required String token,
  }) async {
    try {
      final inputData = {'0': {'json': {'lotCode': lotCode, 'companyId': companyId}}};
      final encodedInput = Uri.encodeComponent(json.encode(inputData));
      final response = await _client
          .get(Uri.parse('$_validateUrl?batch=1&input=$encodedInput'), headers: _authorizedHeaders(token))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 401 || response.statusCode == 403) {
        await clearCache();
        throw LotAccessUnauthorizedException('Your Survey session has expired. Please sign in again.');
      }
      if (response.statusCode != 200) return false;
      final data = json.decode(response.body);
      return data[0]['result']['data']['json']['hasAccess'] as bool;
    } on LotAccessUnauthorizedException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  Future<List<OperationalLot>> getLots(String userId, {required String token, bool forceRefresh = false}) async {
    await _ensureCacheVersion();
    if (!forceRefresh) {
      final cachedLots = await _getCachedLots(userId);
      if (cachedLots.isNotEmpty && !await _isCacheExpired()) return cachedLots;
    }
    return fetchLots(userId, token: token);
  }

  Future<void> _cacheLots(String userId, List<OperationalLot> lots) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, json.encode({'userId': userId, 'lots': lots.map((lot) => lot.toJson()).toList()}));
    await prefs.setInt(_cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setString(_cacheUserIdKey, userId);
    await prefs.setString(_cacheVersionKey, _cacheVersion);
  }

  Future<List<OperationalLot>> _getCachedLots(String userId, {bool ignoreExpiry = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_cacheVersionKey) != _cacheVersion) return [];
      final cachedJson = prefs.getString(_cacheKey);
      final timestamp = prefs.getInt(_cacheTimestampKey);
      final cachedUserId = prefs.getString(_cacheUserIdKey);
      if (cachedJson == null || timestamp == null || cachedUserId != userId) return [];
      if (!ignoreExpiry && DateTime.now().millisecondsSinceEpoch - timestamp > _cacheExpiry.inMilliseconds) return [];
      final cacheData = json.decode(cachedJson);
      if (cacheData['userId'] != userId) return [];
      return (cacheData['lots'] as List)
          .map((lot) => OperationalLot.fromJson(lot as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<bool> _isCacheExpired() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getInt(_cacheTimestampKey);
    return timestamp == null || DateTime.now().millisecondsSinceEpoch - timestamp > _cacheExpiry.inMilliseconds;
  }

  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cacheKey);
    await prefs.remove(_cacheTimestampKey);
    await prefs.remove(_cacheUserIdKey);
    await prefs.remove(_cacheVersionKey);
  }

  Future<OperationalLot?> getLotByCode(String userId, String lotCode, {required String token}) async {
    final lots = await getLots(userId, token: token);
    try {
      return lots.firstWhere((lot) => lot.lotCode == lotCode);
    } catch (_) {
      return null;
    }
  }
}

class LotAccessUnauthorizedException implements Exception {
  final String message;
  LotAccessUnauthorizedException(this.message);
  @override
  String toString() => message;
}
