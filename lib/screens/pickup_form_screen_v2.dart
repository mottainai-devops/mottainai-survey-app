import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../providers/auth_provider.dart';
import '../providers/sync_provider.dart';
import '../models/pickup_submission.dart';
import '../models/company.dart';
import '../models/building_polygon.dart';
import '../database/database_helper.dart';
import '../services/company_service.dart';
import '../services/lot_service.dart';
import '../services/arcgis_service.dart';
import '../widgets/enhanced_location_map.dart';

class PickupFormScreenV2 extends StatefulWidget {
  final Company? preSelectedCompany;
  
  const PickupFormScreenV2({
    super.key,
    this.preSelectedCompany,
  });

  @override
  State<PickupFormScreenV2> createState() => _PickupFormScreenV2State();
}

class _PickupFormScreenV2State extends State<PickupFormScreenV2> {
  final _formKey = GlobalKey<FormState>();
  final _supervisorIdController = TextEditingController();
  final _buildingIdController = TextEditingController();
  final _businessNameController = TextEditingController();
  final _customerPhoneController = TextEditingController();
  final _customerEmailController = TextEditingController();
  final _customerAddressController = TextEditingController();
  final _binQuantityController = TextEditingController();
  final _incidentReportController = TextEditingController();
  
  final CompanyService _companyService = CompanyService();
  final LotService _lotService = LotService();
  final ArcGISService _arcgisService = ArcGISService();
  
  // Company & Lot Selection
  List<Company> _companies = [];
  Company? _selectedCompany;
  OperationalLot? _selectedLot;
  List<OperationalLot> _allLots = []; // All lots from API
  bool _isLoadingCompanies = true;
  bool _isLoadingLots = true;
  
  // Billing Type (PAYT or Monthly Billing)
  String _billingType = 'PAYT';
  final List<String> _billingTypes = ['PAYT', 'Monthly Billing'];
  
  // Customer Type (Residential or Business)
  String _customerType = 'Residential';
  final List<String> _customerTypes = ['Residential', 'Business'];
  
  // Socio-Economic Class (for Residential customers only)
  String _socioClass = 'medium';
  final List<String> _socioClasses = ['low', 'medium', 'high'];
  bool _isSocioClassAutoFilled = false;
  bool _isLoadingSocioClass = false;
  
  // Building data from polygon
  String? _customerZone;
  String? _socioEconomicGroup;
  BuildingPolygon? _selectedBuilding;
  
  // Existing fields
  String _binType = '10 CBM SKIP BIN';
  String? _wheelieBinType;
  DateTime _pickUpDate = DateTime.now();
  File? _firstPhoto;
  File? _secondPhoto;
  bool _isSubmitting = false;
  double? _latitude;
  double? _longitude;

  final List<String> _binTypes = [
    '10 CBM SKIP BIN',
    '6CBM SKIP BIN',
    '240 LITRE WHEELIE BIN',
    '120 LITRE WHEELIE BIN',
  ];
  final List<String> _wheelieBinTypes = ['Residential', 'Commercial'];

  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    
    // Load lots from API (companies will be extracted from lots)
    _loadLots();
  }

  @override
  void dispose() {
    _supervisorIdController.dispose();
    _buildingIdController.dispose();
    _businessNameController.dispose();
    _customerPhoneController.dispose();
    _customerEmailController.dispose();
    _customerAddressController.dispose();
    _binQuantityController.dispose();
    _incidentReportController.dispose();
    super.dispose();
  }

  // ignore: unused_element
  Future<void> _loadCompanies() async {
    setState(() {
      _isLoadingCompanies = true;
    });

    try {
      final companies = await _companyService.getCompanies();
      setState(() {
        _companies = companies;
        _isLoadingCompanies = false;
      });

      if (companies.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No companies available. Please check your connection.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _isLoadingCompanies = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load companies: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _handleBuildingSelected(BuildingPolygon polygon) async {
    setState(() {
      _selectedBuilding = polygon;
      _buildingIdController.text = polygon.buildingId;
      _businessNameController.text = polygon.businessName ?? '';
      _customerPhoneController.text = polygon.custPhone ?? '';
      _customerEmailController.text = polygon.customerEmail ?? '';
      _customerAddressController.text = polygon.address ?? '';
      _customerZone = polygon.zone;
      _socioEconomicGroup = polygon.socioEconomicGroups;
    });
    
    // Auto-populate socio-economic class from ArcGIS
    await _loadSocioEconomicClass(polygon.buildingId);
  }
  
  /// Load socio-economic class from ArcGIS feature layer
  Future<void> _loadSocioEconomicClass(String buildingId) async {
    // Only auto-fill for residential customers
    if (_customerType != 'Residential') {
      return;
    }
    
    setState(() {
      _isLoadingSocioClass = true;
    });
    
    try {
      final socioClassValue = await _arcgisService.getSocioEconomicClass(buildingId);
      
      if (socioClassValue != null && mounted) {
        // Auto-fill successful
        setState(() {
          _socioClass = socioClassValue;
          _isSocioClassAutoFilled = true;
          _isLoadingSocioClass = false;
        });
        
        // Show success message
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Socio-class auto-filled: ${socioClassValue.toUpperCase()}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 3),
          ),
        );
      } else if (mounted) {
        // Auto-fill failed - user can select manually
        setState(() {
          _isSocioClassAutoFilled = false;
          _isLoadingSocioClass = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.white),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Please select socio-class manually'),
                ),
              ],
            ),
            backgroundColor: Colors.orange.shade700,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      print('[PickupForm] Error loading socio-class: $e');
      if (mounted) {
        setState(() {
          _isSocioClassAutoFilled = false;
          _isLoadingSocioClass = false;
        });
      }
    }
  }

  Future<void> _pickImage(bool isFirst) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        final appDir = await getApplicationDocumentsDirectory();
        final fileName = '${DateTime.now().millisecondsSinceEpoch}_${path.basename(image.path)}';
        final savedImage = File('${appDir.path}/$fileName');
        await File(image.path).copy(savedImage.path);

        setState(() {
          if (isFirst) {
            _firstPhoto = savedImage;
          } else {
            _secondPhoto = savedImage;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to pick image: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _loadLots() async {
    setState(() {
      _isLoadingLots = true;
    });

    try {
      // Get user ID from auth provider
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      if (authProvider.user == null) {
        throw Exception('User not authenticated');
      }
      
      final userId = authProvider.user!.id;
      final lots = await _lotService.getLots(userId);
      
      // Extract unique companies from lots
      final companiesMap = <String, Company>{};
      for (final lot in lots) {
        final companyId = lot.companyId;
        final companyName = lot.companyName;
        if (!companiesMap.containsKey(companyId)) {
          companiesMap[companyId] = Company(
            id: companyId,
            companyId: companyId,
            companyName: companyName,
            pinCode: '', // Not used anymore
            operationalLots: [],
            isActive: true,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
        }
      }
      
      setState(() {
        _allLots = lots;
        _companies = companiesMap.values.toList();
        _isLoadingLots = false;
        _isLoadingCompanies = false;
      });

      if (lots.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No operational lots available for your account. Please contact your administrator.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        print('Loaded ${lots.length} lots from API for user $userId');
      }
    } catch (e) {
      setState(() {
        _isLoadingLots = false;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load lots from API: $e'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  // ignore: unused_element
  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _pickUpDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null && picked != _pickUpDate) {
      setState(() {
        _pickUpDate = picked;
      });
    }
  }

  Future<void> _submitForm() async {
    // Validate company and lot selection
    if (_selectedCompany == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a company'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_selectedLot == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select an operational lot'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill all required fields'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_firstPhoto == null || _secondPhoto == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please capture both photos'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    if (_latitude == null || _longitude == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please set pickup location on map'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final authProvider = Provider.of<AuthProvider>(context, listen: false);
      final syncProvider = Provider.of<SyncProvider>(context, listen: false);

      // Get webhook URL based on company, lot, and billing type
      final webhookUrl = _companyService.getWebhookUrl(
        company: _selectedCompany!,
        lot: _selectedLot!,
        customerType: _billingType,
      );

      final pickup = PickupSubmission(
        formId: webhookUrl, // Use webhook URL as form ID for routing
        supervisorId: _supervisorIdController.text.trim(),
        customerType: '$_billingType - $_customerType', // Combined billing and customer type
        binType: _binType,
        wheelieBinType: _wheelieBinType,
        binQuantity: int.parse(_binQuantityController.text.trim()),
        buildingId: _buildingIdController.text.trim(),
        pickUpDate: DateFormat('MMM dd, yyyy').format(_pickUpDate),
        firstPhoto: _firstPhoto!.path,
        secondPhoto: _secondPhoto!.path,
        incidentReport: _incidentReportController.text.trim().isEmpty
            ? null
            : _incidentReportController.text.trim(),
        userId: authProvider.user!.id,
        latitude: _latitude,
        longitude: _longitude,
        createdAt: DateTime.now().toIso8601String(),
        companyId: authProvider.user!.companyId ?? _selectedCompany?.companyId,
        companyName: authProvider.user!.companyName ?? _selectedCompany?.companyName,
        lotCode: _selectedLot?.lotCode,
        lotName: _selectedLot?.lotName,
        socioClass: _customerType == 'Residential' ? _socioClass : null,
      );

      // Save to local database
      await DatabaseHelper.instance.createPickup(pickup);
      await syncProvider.incrementUnsyncedCount();

      if (mounted) {
        // Try to sync immediately if online
        syncProvider.syncPendingPickups();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pickup saved! Will sync when online.'),
            backgroundColor: Colors.green,
          ),
        );

        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save pickup: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('New Pickup'),
        actions: [
          if (_isLoadingCompanies)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Company Selection
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Company & Operational Lot',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Show read-only company info if pre-selected via PIN
                    if (widget.preSelectedCompany != null)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.green.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.green.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.verified, color: Colors.green.shade700),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Authenticated Company',
                                    style: TextStyle(
                                      fontSize: 8,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _selectedCompany!.companyName,
                                    style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    'ID: ${_selectedCompany!.companyId}',
                                    style: TextStyle(
                                      fontSize: 8,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      // Show dropdown if no pre-selected company
                      DropdownButtonFormField<Company>(
                        value: _selectedCompany,
                        decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                          labelText: 'Company *',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          prefixIcon: const Icon(Icons.business),
                        ),
                        items: _companies.map((company) {
                          return DropdownMenuItem(
                            value: company,
                            child: Text(company.companyName),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedCompany = value;
                            _selectedLot = null; // Reset lot when company changes
                          });
                        },
                        validator: (value) {
                          if (value == null) {
                            return 'Please select a company';
                          }
                          return null;
                        },
                      ),
                    const SizedBox(height: 16),
                    // Lot dropdown - uses API lots if available, falls back to company lots
                    DropdownButtonFormField<OperationalLot>(
                      value: _selectedLot,
                      decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                        labelText: 'Operational Lot *',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        prefixIcon: const Icon(Icons.location_city),
                        suffixIcon: _isLoadingLots
                            ? const Padding(
                                padding: EdgeInsets.all(12.0),
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              )
                            : null,
                      ),
                      items: (_allLots.isNotEmpty
                              ? _allLots
                              : (_selectedCompany?.operationalLots ?? []))
                          .map((lot) {
                        return DropdownMenuItem(
                          value: lot,
                          child: Text('${lot.lotCode} - ${lot.lotName}'),
                        );
                      }).toList(),
                      onChanged: _isLoadingLots
                          ? null
                          : (value) {
                              setState(() {
                                _selectedLot = value;
                              });
                            },
                      validator: (value) {
                        if (value == null) {
                          return 'Please select an operational lot';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Supervisor ID
            TextFormField(
              controller: _supervisorIdController,
              decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                labelText: 'Supervisor ID *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: const Icon(Icons.badge),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter supervisor ID';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Enhanced Location Map with Polygon Overlay
            const Text(
              'Pickup Location *',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Tap on a building polygon to auto-fill customer information',
              style: TextStyle(
                fontSize: 8,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            // EnhancedLocationMap contains a fixed-height 400px map internally.
            // Removing the outer SizedBox constraint prevents the widget from
            // overflowing its bounds and overlapping the Building Information
            // card that follows it in the ListView.
            EnhancedLocationMap(
              onLocationSelected: (lat, lon) {
                setState(() {
                  _latitude = lat;
                  _longitude = lon;
                });
              },
              onBuildingSelected: _handleBuildingSelected,
            ),
            const SizedBox(height: 16),

            // Building Information (Auto-filled from polygon)
            Card(
              color: _selectedBuilding != null ? Colors.blue.shade50 : null,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.business,
                          color: _selectedBuilding != null ? Colors.blue : Colors.grey,
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Building Information',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_selectedBuilding != null) ...[
                          const Spacer(),
                          const Icon(Icons.check_circle, color: Colors.green, size: 20),
                        ],
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    // Building ID (Required)
                    TextFormField(
                      controller: _buildingIdController,
                      decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                        labelText: 'Building ID *',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        prefixIcon: const Icon(Icons.tag),
                        filled: true,
                        fillColor: _selectedBuilding != null 
                            ? Colors.blue.shade50 
                            : Colors.white,
                      ),
                      readOnly: _selectedBuilding != null,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Building ID is required. Please select a building on the map.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    
                    // Business Name
                    TextFormField(
                      controller: _businessNameController,
                      decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                        labelText: 'Business Name',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        prefixIcon: const Icon(Icons.store),
                      ),
                    ),
                    const SizedBox(height: 12),
                    
                    // Customer Phone
                    TextFormField(
                      controller: _customerPhoneController,
                      decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                        labelText: 'Customer Phone',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        prefixIcon: const Icon(Icons.phone),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 12),
                    
                    // Customer Email
                    TextFormField(
                      controller: _customerEmailController,
                      decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                        labelText: 'Customer Email',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        prefixIcon: const Icon(Icons.email),
                      ),
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 12),
                    
                    // Customer Address
                    TextFormField(
                      controller: _customerAddressController,
                      decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                        labelText: 'Customer Address',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        prefixIcon: const Icon(Icons.location_on),
                      ),
                      maxLines: 2,
                    ),
                    
                    // Zone and Socio-Economic Group (Read-only, from polygon)
                    if (_customerZone != null || _socioEconomicGroup != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_customerZone != null)
                              Row(
                                children: [
                                  const Icon(Icons.map, size: 16, color: Colors.grey),
                                  const SizedBox(width: 8),
                                  const Text('Zone: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                  Text(_customerZone!),
                                ],
                              ),
                            if (_socioEconomicGroup != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  const Icon(Icons.group, size: 16, color: Colors.grey),
                                  const SizedBox(width: 8),
                                  const Text('Socio-Economic Group: ', style: TextStyle(fontWeight: FontWeight.bold)),
                                  Text(_socioEconomicGroup!),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Billing Type (PAYT or Monthly Billing)
            const Text(
              'Billing Type *',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: _billingTypes.map((type) {
                return Expanded(
                  child: RadioListTile<String>(
                    title: Text(type),
                    value: type,
                    groupValue: _billingType,
                    onChanged: (value) {
                      setState(() {
                        _billingType = value!;
                      });
                    },
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            
            // Customer Type (Residential or Business)
            const Text(
              'Customer Type *',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: _customerTypes.map((type) {
                return Expanded(
                  child: RadioListTile<String>(
                    title: Text(type),
                    value: type,
                    groupValue: _customerType,
                    onChanged: (value) {
                      setState(() {
                        _customerType = value!;
                      });
                    },
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            
            // Socio-Economic Class (only for Residential customers)
            if (_customerType == 'Residential')
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        'Socio-Economic Class *',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (_isSocioClassAutoFilled) ...<Widget>[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.green.shade700,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.check_circle, color: Colors.white, size: 14),
                              SizedBox(width: 4),
                              Text(
                                'Auto-filled',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isLoadingSocioClass)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.shade200),
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.blue.shade700),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'Loading socio-class from ArcGIS...',
                            style: TextStyle(
                              fontSize: 14,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      children: _socioClasses.map((socioClass) {
                        return Expanded(
                          child: RadioListTile<String>(
                            title: Text(socioClass.toUpperCase()),
                            value: socioClass,
                            groupValue: _socioClass,
                            onChanged: (value) {
                              setState(() {
                                _socioClass = value!;
                                _isSocioClassAutoFilled = false; // Mark as manually changed
                              });
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 16),
                ],
              ),

            // Bin Type
            DropdownButtonFormField<String>(
              value: _binType,
              decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                labelText: 'Bin Type *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: const Icon(Icons.delete),
              ),
              items: _binTypes.map((type) {
                return DropdownMenuItem(
                  value: type,
                  child: Text(type),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _binType = value!;
                });
              },
            ),
            const SizedBox(height: 16),

            // Wheelie Bin Type (conditional)
            if (_binType.contains('WHEELIE'))
              Column(
                children: [
                  DropdownButtonFormField<String>(
                    value: _wheelieBinType,
                    decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                      labelText: 'Wheelie Bin Type',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      prefixIcon: const Icon(Icons.category),
                    ),
                    items: _wheelieBinTypes.map((type) {
                      return DropdownMenuItem(
                        value: type,
                        child: Text(type),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _wheelieBinType = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ),

            // Bin Quantity
            TextFormField(
              controller: _binQuantityController,
              decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                labelText: 'Bin Quantity *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: const Icon(Icons.numbers),
              ),
              keyboardType: TextInputType.number,
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter bin quantity';
                }
                if (int.tryParse(value) == null) {
                  return 'Please enter a valid number';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // Pick-up Date
            ListTile(
              title: const Text('Pick-up Date *'),
              subtitle: Text(DateFormat('MMM dd, yyyy').format(_pickUpDate)),
              leading: const Icon(Icons.calendar_today),
              trailing: null,  // Removed edit icon to indicate read-only
              onTap: null,  // Disabled tap to make it read-only
              enabled: false,  // Make it visually disabled
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: Colors.grey.shade300),
              ),
            ),
            const SizedBox(height: 16),

            // Photos
            const Text(
              'Photos *',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => _pickImage(true),
                    child: Container(
                      height: 150,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey.shade100,
                      ),
                      child: _firstPhoto != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                _firstPhoto!,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.camera_alt, size: 48, color: Colors.grey),
                                SizedBox(height: 8),
                                Text('First Photo'),
                              ],
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: GestureDetector(
                    onTap: () => _pickImage(false),
                    child: Container(
                      height: 150,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8),
                        color: Colors.grey.shade100,
                      ),
                      child: _secondPhoto != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                _secondPhoto!,
                                fit: BoxFit.cover,
                              ),
                            )
                          : const Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.camera_alt, size: 48, color: Colors.grey),
                                SizedBox(height: 8),
                                Text('Second Photo'),
                              ],
                            ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Incident Report (Optional)
            TextFormField(
              controller: _incidentReportController,
              decoration: InputDecoration(
                  labelStyle: const TextStyle(fontSize: 16, color: Color(0xFF6B7280)),
                labelText: 'Incident Report (Optional)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: const Icon(Icons.report),
                hintText: 'Describe any incidents or issues...',
                hintStyle: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 24),

            // Submit Button
            ElevatedButton(
              onPressed: _isSubmitting ? null : _submitForm,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      'Submit Pickup',
                      style: TextStyle(fontSize: 16),
                    ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
