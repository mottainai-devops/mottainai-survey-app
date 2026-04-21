import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/sync_provider.dart';
import '../models/pickup_submission.dart';
import 'dart:io';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    _loadHistory();
    _setupSyncListener();
  }

  void _setupSyncListener() {
    // Listen for sync completion and reload history
    final syncProvider = Provider.of<SyncProvider>(context, listen: false);
    syncProvider.addListener(() {
      if (!syncProvider.isSyncing && mounted) {
        // Sync completed, reload history to show updated status
        _loadHistory();
      }
    });
  }

  Future<void> _loadHistory() async {
    // Trigger a rebuild to show latest data
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final syncProvider = Provider.of<SyncProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Pickup History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadHistory,
          ),
        ],
      ),
      body: FutureBuilder<List<PickupSubmission>>(
        future: syncProvider.getAllPickups(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error, size: 48, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('Error: ${snapshot.error}'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _loadHistory,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final pickups = snapshot.data ?? [];

          if (pickups.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No pickups recorded yet',
                    style: TextStyle(
                      fontSize: 18,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _loadHistory,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: pickups.length,
              itemBuilder: (context, index) {
                final pickup = pickups[index];
                return _buildPickupCard(pickup);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildPickupCard(PickupSubmission pickup) {
    final isSynced = pickup.synced == 1;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: () => _showPickupDetails(pickup),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Row
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Building: ${pickup.buildingId}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          pickup.customerType,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isSynced ? Colors.green.shade50 : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSynced ? Icons.cloud_done : Icons.cloud_upload,
                          size: 16,
                          color: isSynced ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isSynced ? 'Synced' : 'Pending',
                          style: TextStyle(
                            fontSize: 12,
                            color: isSynced ? Colors.green : Colors.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Details
              if (pickup.userIdentificationNumber != null && pickup.userIdentificationNumber!.isNotEmpty)
                _buildDetailRow(Icons.badge, 'Customer ID', pickup.userIdentificationNumber!),
              _buildDetailRow(Icons.delete, 'Bin Type', pickup.binType),
              _buildDetailRow(Icons.numbers, 'Quantity', '${pickup.binQuantity}'),
              _buildDetailRow(Icons.calendar_today, 'Date', pickup.pickUpDate),
              
              if (pickup.incidentReport != null && pickup.incidentReport!.isNotEmpty)
                _buildDetailRow(
                  Icons.report,
                  'Incident',
                  pickup.incidentReport!,
                ),

              const SizedBox(height: 8),
              
              // Created At
              Text(
                'Recorded: ${_formatDateTime(pickup.createdAt)}',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(String isoString) {
    try {
      final dateTime = DateTime.parse(isoString);
      return DateFormat('MMM dd, yyyy HH:mm').format(dateTime);
    } catch (e) {
      return isoString;
    }
  }

  void _showPickupDetails(PickupSubmission pickup) {
    final supervisorController = TextEditingController(text: pickup.supervisorId);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (ctx2, scrollController) {
          return SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Pickup Details',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(height: 32),

                // Building ID
                _buildDetailSection('Building ID', pickup.buildingId),
                if (pickup.userIdentificationNumber != null && pickup.userIdentificationNumber!.isNotEmpty)
                  _buildDetailSection('Customer ID', pickup.userIdentificationNumber!),

                // Supervisor ID — editable for unsynced submissions, read-only for synced
                if (pickup.synced == 0) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Supervisor ID',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: supervisorController,
                                decoration: InputDecoration(
                                  hintText: 'Enter supervisor ID',
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                style: const TextStyle(fontSize: 15),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: () async {
                                final newId = supervisorController.text.trim();
                                if (newId.isEmpty) return;
                                final syncProvider = Provider.of<SyncProvider>(ctx, listen: false);
                                await syncProvider.updateSupervisorId(pickup.id!, newId);
                                if (ctx.mounted) Navigator.pop(ctx);
                                if (mounted) {
                                  _loadHistory();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Supervisor ID saved — tap Sync to retry'),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  _buildDetailSection('Supervisor ID', pickup.supervisorId),
                ],

                _buildDetailSection('Customer Type', pickup.customerType),
                _buildDetailSection('Bin Type', pickup.binType),
                if (pickup.wheelieBinType != null)
                  _buildDetailSection('Wheelie Bin Type', pickup.wheelieBinType!),
                _buildDetailSection('Bin Quantity', '${pickup.binQuantity}'),
                _buildDetailSection('Pick Up Date', pickup.pickUpDate),
                if (pickup.latitude != null && pickup.longitude != null)
                  _buildDetailSection(
                    'Location',
                    'Lat: ${pickup.latitude!.toStringAsFixed(6)}, Lon: ${pickup.longitude!.toStringAsFixed(6)}',
                  ),
                if (pickup.incidentReport != null && pickup.incidentReport!.isNotEmpty)
                  _buildDetailSection('Incident Report', pickup.incidentReport!),
                _buildDetailSection('Status', pickup.synced == 1 ? 'Synced' : 'Pending Sync'),
                _buildDetailSection('Recorded At', _formatDateTime(pickup.createdAt)),

                const SizedBox(height: 24),

                // Photos
                const Text(
                  'Photos',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),

                Row(
                  children: [
                    Expanded(
                      child: _buildPhotoPreview('First Photo', pickup.firstPhoto),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildPhotoPreview('Second Photo', pickup.secondPhoto),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Delete Button (only for unsynced)
                if (pickup.synced == 0)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _deletePickup(pickup),
                      icon: const Icon(Icons.delete),
                      label: const Text('Delete Pickup'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDetailSection(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoPreview(String label, String photoPath) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 1,
            child: File(photoPath).existsSync()
                ? Image.file(
                    File(photoPath),
                    fit: BoxFit.cover,
                  )
                : Container(
                    color: Colors.grey.shade300,
                    child: const Icon(Icons.image_not_supported),
                  ),
          ),
        ),
      ],
    );
  }

  Future<void> _deletePickup(PickupSubmission pickup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Pickup'),
        content: const Text('Are you sure you want to delete this pickup? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final syncProvider = Provider.of<SyncProvider>(context, listen: false);
      await syncProvider.deletePickup(pickup.id!);
      
      if (mounted) {
        Navigator.pop(context); // Close bottom sheet
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Pickup deleted'),
            backgroundColor: Colors.green,
          ),
        );
        _loadHistory(); // Refresh list
      }
    }
  }
}
