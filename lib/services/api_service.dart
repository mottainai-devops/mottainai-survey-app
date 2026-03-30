import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import '../models/user.dart';
import '../models/pickup_submission.dart';

class ApiService {
  // Backend API base URL
  static const String baseUrl = 'https://upwork.kowope.xyz';
  
  String? _token;

  void setToken(String token) {
    _token = token;
  }

  String? getToken() {
    return _token;
  }

  void clearToken() {
    _token = null;
  }

  Map<String, String> _getHeaders() {
    final headers = {
      'Content-Type': 'application/json',
    };
    if (_token != null) {
      headers['Authorization'] = _token!;
    }
    return headers;
  }

  Future<Map<String, dynamic>> login(String email, String password) async {
    try {
      // Password needs to be base64 encoded as per backend requirement
      final encodedPassword = base64.encode(utf8.encode(password));
      
      final response = await http.post(
        Uri.parse('$baseUrl/users/login'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'email': email,
          'password': encodedPassword,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _token = data['token'];
        return {
          'success': true,
          'token': data['token'],
          'user': User.fromJson(data['user']),
        };
      } else {
        final error = json.decode(response.body);
        return {
          'success': false,
          'error': error['error'] ?? 'Login failed',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: $e',
      };
    }
  }

  Future<Map<String, dynamic>> getMe() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/mobile/users/me'),
        headers: _getHeaders(),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'success': true,
          'user': User.fromJson(data['user']),
        };
      } else {
        return {
          'success': false,
          'error': 'Failed to get user info',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: $e',
      };
    }
  }

  Future<Map<String, dynamic>> submitPickup(
    PickupSubmission pickup,
    File firstPhotoFile,
    File secondPhotoFile,
  ) async {
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$baseUrl/forms/submit'),
      );

      // Add authorization header
      if (_token != null) {
        request.headers['Authorization'] = _token!;
      }

      // ── Routing & identity fields (REQUIRED by backend) ─────────────────
      // formId is the webhook URL that tells the backend which form/lot this
      // submission belongs to. Without it the backend cannot route the request
      // and will reject it. supervisorId identifies the field supervisor.
      request.fields['formId'] = pickup.formId;
      request.fields['supervisorId'] = pickup.supervisorId;

      // Customer contact fields (fixed in v3.2.5 — previously sent as empty strings)
      request.fields['customerName'] = pickup.customerName;
      request.fields['customerPhone'] = pickup.customerPhone;
      request.fields['customerEmail'] = pickup.customerEmail;
      request.fields['customerAddress'] = pickup.customerAddress;

      // Pickup fields
      request.fields['customerType'] = pickup.customerType;
      if (pickup.socioClass != null) {
        request.fields['socioClass'] = pickup.socioClass!;
      }
      request.fields['binType'] = pickup.binType;
      if (pickup.wheelieBinType != null) {
        request.fields['wheelieBinType'] = pickup.wheelieBinType!;
      }
      request.fields['binQuantity'] = pickup.binQuantity.toString();
      request.fields['buildingId'] = pickup.buildingId;
      request.fields['pickUpDate'] = pickup.pickUpDate;
      if (pickup.incidentReport != null && pickup.incidentReport!.isNotEmpty) {
        request.fields['incidentReport'] = pickup.incidentReport!;
      }
      request.fields['userId'] = pickup.userId;
      if (pickup.latitude != null) {
        request.fields['latitude'] = pickup.latitude.toString();
      }
      if (pickup.longitude != null) {
        request.fields['longitude'] = pickup.longitude.toString();
      }
      request.fields['createdAt'] = pickup.createdAt;
      if (pickup.companyId != null) {
        request.fields['companyId'] = pickup.companyId!;
      }
      if (pickup.companyName != null) {
        request.fields['companyName'] = pickup.companyName!;
      }
      if (pickup.lotCode != null) {
        request.fields['lotCode'] = pickup.lotCode!;
      }
      if (pickup.lotName != null) {
        request.fields['lotName'] = pickup.lotName!;
      }
      // ArcGIS Footprint Polygon building_id — added v3.3.0
      if (pickup.arcgisBuildingId != null && pickup.arcgisBuildingId!.isNotEmpty) {
        request.fields['arcgisBuildingId'] = pickup.arcgisBuildingId!;
      }

      // Add photo files
      request.files.add(await http.MultipartFile.fromPath(
        'firstPhoto',
        firstPhotoFile.path,
        contentType: MediaType('image', 'jpeg'),
      ));

      request.files.add(await http.MultipartFile.fromPath(
        'secondPhoto',
        secondPhotoFile.path,
        contentType: MediaType('image', 'jpeg'),
      ));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        return {
          'success': true,
          'message': 'Pickup submitted successfully',
        };
      } else {
        // Log the full error for debugging
        print('[API] Pickup submission failed: ${response.statusCode}');
        print('[API] Response body: ${response.body}');
        
        // Check if response is HTML (backend error page)
        final isHtmlError = response.body.toLowerCase().contains('<html') || 
                           response.body.toLowerCase().contains('<!doctype');
        
        String userFriendlyError;
        if (isHtmlError) {
          // Don't show HTML error pages to users
          userFriendlyError = 'Server error (${response.statusCode}). Please try again or contact support.';
        } else {
          // Try to parse JSON error message
          try {
            final errorData = jsonDecode(response.body);
            userFriendlyError = errorData['message'] ?? errorData['error'] ?? 'Unknown error';
          } catch (e) {
            // If not JSON, show the raw message (truncated)
            final truncated = response.body.length > 200 
                ? '${response.body.substring(0, 200)}...' 
                : response.body;
            userFriendlyError = truncated;
          }
        }
        
        return {
          'success': false,
          'error': userFriendlyError,
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: $e',
      };
    }
  }

  Future<bool> checkConnection() async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // Check if a building has existing customers
  Future<Map<String, dynamic>> checkBuilding(String buildingId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/v1/buildings/$buildingId/check'),
        headers: _getHeaders(),
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        return {
          'success': false,
          'error': 'Failed to check building',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: $e',
      };
    }
  }

  // Get existing customers for a building
  Future<Map<String, dynamic>> getBuildingCustomers(String buildingId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/v1/buildings/$buildingId/customers'),
        headers: _getHeaders(),
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else {
        return {
          'success': false,
          'error': 'Failed to get customers',
        };
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Network error: $e',
      };
    }
  }
}
