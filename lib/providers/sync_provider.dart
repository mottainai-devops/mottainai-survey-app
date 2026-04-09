import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/database_helper.dart';
import '../services/api_service.dart';
import '../models/pickup_submission.dart';

class SyncProvider with ChangeNotifier {
  final ApiService _apiService = ApiService();
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  
  bool _isSyncing = false;
  int _unsyncedCount = 0;
  String? _lastSyncError;
  DateTime? _lastSyncTime;
  bool _isOnline = true;

  bool get isSyncing => _isSyncing;
  int get unsyncedCount => _unsyncedCount;
  String? get lastSyncError => _lastSyncError;
  DateTime? get lastSyncTime => _lastSyncTime;
  bool get isOnline => _isOnline;

  SyncProvider() {
    _initConnectivityListener();
    _loadUnsyncedCount();
    _loadTokenFromStorage();
  }

  Future<void> _loadTokenFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      if (token != null) {
        _apiService.setToken(token);
        print('[SyncProvider] Token loaded from storage');
      } else {
        print('[SyncProvider] No token found in storage');
      }
    } catch (e) {
      print('[SyncProvider] Error loading token: $e');
    }
  }

  void _initConnectivityListener() {
    Connectivity().onConnectivityChanged.listen((result) async {
      final wasOffline = !_isOnline;
      _isOnline = result != ConnectivityResult.none;
      notifyListeners();

      // Auto-sync when coming back online
      if (wasOffline && _isOnline && _unsyncedCount > 0) {
        await syncPendingPickups();
      }
    });

    // Check initial connectivity
    Connectivity().checkConnectivity().then((result) {
      _isOnline = result != ConnectivityResult.none;
      notifyListeners();
    });
  }

  Future<void> _loadUnsyncedCount() async {
    _unsyncedCount = await _dbHelper.getUnsyncedCount();
    notifyListeners();
  }

  Future<void> incrementUnsyncedCount() async {
    await _loadUnsyncedCount();
  }

  Future<void> syncPendingPickups() async {
    if (_isSyncing) return;

    _isSyncing = true;
    _lastSyncError = null;
    notifyListeners();

    try {
      // Check if online
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity == ConnectivityResult.none) {
        _lastSyncError = 'No internet connection';
        _isSyncing = false;
        notifyListeners();
        return;
      }

      // Get unsynced pickups
      final unsyncedPickups = await _dbHelper.getUnsyncedPickups();
      
      if (unsyncedPickups.isEmpty) {
        _isSyncing = false;
        _lastSyncTime = DateTime.now();
        notifyListeners();
        return;
      }

      // Ensure token is loaded before submitting
      await _loadTokenFromStorage();

      int successCount = 0;
      int failCount = 0;
      final List<String> errorDetails = [];

      for (final pickup in unsyncedPickups) {
        try {
          // Get photo files
          final firstPhoto = File(pickup.firstPhoto);
          final secondPhoto = File(pickup.secondPhoto);

          // Check if files exist — surface a clear error if missing
          if (!await firstPhoto.exists()) {
            final msg = 'Photo 1 missing for #${pickup.id}';
            debugPrint('[SyncProvider] $msg (path: ${pickup.firstPhoto})');
            errorDetails.add(msg);
            failCount++;
            continue;
          }
          if (!await secondPhoto.exists()) {
            final msg = 'Photo 2 missing for #${pickup.id}';
            debugPrint('[SyncProvider] $msg (path: ${pickup.secondPhoto})');
            errorDetails.add(msg);
            failCount++;
            continue;
          }

          // Submit to server
          final result = await _apiService.submitPickup(
            pickup,
            firstPhoto,
            secondPhoto,
          );

          if (result['success'] == true) {
            // Mark as synced in local database
            await _dbHelper.markAsSynced(pickup.id!);
            successCount++;
          } else {
            final serverError = result['error'] ?? 'Unknown server error';
            debugPrint('[SyncProvider] Server rejected #${pickup.id}: $serverError');
            errorDetails.add('Server: $serverError');
            failCount++;
          }
        } catch (e) {
          debugPrint('[SyncProvider] Exception syncing #${pickup.id}: $e');
          errorDetails.add('Exception: $e');
          failCount++;
        }
      }

      await _loadUnsyncedCount();
      _lastSyncTime = DateTime.now();
      
      if (failCount > 0) {
        // Show the first specific error so the user knows what to fix
        final detail = errorDetails.isNotEmpty ? '\n${errorDetails.first}' : '';
        _lastSyncError = 'Synced $successCount, failed $failCount$detail';
      }

      _isSyncing = false;
      notifyListeners();
    } catch (e) {
      _lastSyncError = 'Sync failed: $e';
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<List<PickupSubmission>> getAllPickups() async {
    return await _dbHelper.getAllPickups();
  }

  Future<void> deletePickup(int id) async {
    await _dbHelper.deletePickup(id);
    await _loadUnsyncedCount();
  }

  /// Update supervisorId for a stuck submission so it can be retried without starting over
  Future<void> updateSupervisorId(int id, String supervisorId) async {
    await _dbHelper.updateSupervisorId(id, supervisorId);
    notifyListeners();
  }
}
