import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/violation_storage_service.dart';

class CalibrationsListScreen extends StatefulWidget {
  const CalibrationsListScreen({super.key});

  @override
  State<CalibrationsListScreen> createState() => _CalibrationsListScreenState();
}

class _CalibrationsListScreenState extends State<CalibrationsListScreen> {
  final ViolationStorageService _storage = ViolationStorageService();
  List<Map<String, dynamic>> _calibrations = [];
  String? _activeId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    final list = await _storage.getSavedTopologies();
    final activeMap = await _storage.loadTopology();
    
    String? activeId;
    if (activeMap != null) {
      activeId = activeMap['id'] as String?;
    }

    if (mounted) {
      setState(() {
        _calibrations = list;
        _activeId = activeId;
        _loading = false;
      });
    }
  }

  Future<void> _selectActive(String id) async {
    await _storage.makeTopologyActive(id);
    await _loadData();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Zone configuration updated successfully!'),
          backgroundColor: const Color(0xFF00D4FF),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  Future<void> _delete(String id) async {
    await _storage.deleteTopology(id);
    await _loadData();
  }

  Future<void> _clearAll() async {
    await _storage.deleteAllTopologies();
    await _loadData();
  }

  Future<void> _handleCalibrateNewZone() async {
    final prefs = await SharedPreferences.getInstance();
    final method = prefs.getString('calibration_method') ?? 'automated';
    if (!mounted) return;
    if (method == 'automated') {
      await Navigator.pushNamed(
        context,
        '/detect',
        arguments: {'forceCalibrate': true},
      );
    } else {
      await Navigator.pushNamed(
        context,
        '/calibrate',
      );
    }
    _loadData();
  }

  void _showDeleteConfirm(String id, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Delete Calibration',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Text('Are you sure you want to delete "$name"?',
            style: const TextStyle(color: Colors.white60)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _delete(id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF3B30),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showClearAllConfirm() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Clear All Calibrations',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
            'This will permanently delete all saved calibrations and reset the system zones.',
            style: TextStyle(color: Colors.white60)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _clearAll();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF3B30),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080810),
      body: CustomScrollView(
        slivers: [
          // ── App bar ──────────────────────────────────────────────────────
          SliverAppBar(
            backgroundColor: const Color(0xFF080810),
            foregroundColor: Colors.white,
            pinned: true,
            expandedHeight: 110,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
              title: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Calibrations',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          color: Colors.white,
                          letterSpacing: -0.5)),
                  Text('${_calibrations.length} configurations saved',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12)),
                ],
              ),
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF12121F), Color(0xFF080810)],
                  ),
                ),
              ),
            ),
            actions: [
              if (_calibrations.isNotEmpty)
                IconButton(
                  onPressed: _showClearAllConfirm,
                  icon: const Icon(Icons.delete_sweep_rounded,
                      color: Color(0xFFFF3B30)),
                  tooltip: 'Delete All',
                ),
              const SizedBox(width: 4),
            ],
          ),

          // ── Body ─────────────────────────────────────────────────────────
          if (_loading)
            const SliverFillRemaining(
              child: Center(
                  child: CircularProgressIndicator(color: Color(0xFF00D4FF))),
            )
          else if (_calibrations.isEmpty)
            SliverFillRemaining(child: _buildEmpty())
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 170),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    final c = _calibrations[i];
                    final id = c['id'] as String? ?? '';
                    final name = c['name'] as String? ?? 'Untitled';
                    final isActive = id == _activeId;
                    final zonesList = c['zones'] as List? ?? [];
                    
                    int roadCount = 0;
                    int footpathCount = 0;
                    int dividerCount = 0;
                    int sidelandCount = 0;

                    for (final z in zonesList) {
                      final typeStr = z['zoneType'] as String?;
                      if (typeStr == 'road') roadCount++;
                      else if (typeStr == 'footpath') footpathCount++;
                      else if (typeStr == 'divider') dividerCount++;
                      else if (typeStr == 'sideland') sidelandCount++;
                    }

                    return _CalibrationCard(
                      name: name,
                      isActive: isActive,
                      roadCount: roadCount,
                      footpathCount: footpathCount,
                      dividerCount: dividerCount,
                      sidelandCount: sidelandCount,
                      onTap: () => _selectActive(id),
                      onDelete: () => _showDeleteConfirm(id, name),
                    );
                  },
                  childCount: _calibrations.length,
                ),
              ),
            ),
        ],
      ),
      bottomSheet: _loading || _calibrations.isEmpty ? null : _buildBottomSheet(),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFF00D4FF).withOpacity(0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.layers_clear_outlined,
                size: 38, color: Color(0xFF00D4FF)),
          ),
          const SizedBox(height: 20),
          const Text('No Saved Zones',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Calibrate a new zone using road segmentation to start detecting violations.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white30, fontSize: 13, height: 1.4),
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: 220,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _handleCalibrateNewZone,
              icon: const Icon(Icons.add_location_alt_rounded, size: 18),
              label: const Text(
                'Calibrate New Zone',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00D4FF),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomSheet() {
    return Container(
      color: const Color(0xFF080810),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _activeId == null
                  ? null
                  : () {
                      Navigator.pushNamed(
                        context,
                        '/detect',
                        arguments: {'useSaved': true},
                      );
                    },
              icon: const Icon(Icons.play_circle_filled_rounded),
              label: const Text(
                'Start Detection with Selected Zone',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF34C759),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.white.withOpacity(0.04),
                disabledForegroundColor: Colors.white24,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: _handleCalibrateNewZone,
              icon: const Icon(Icons.add_location_alt_rounded, color: Color(0xFF00D4FF)),
              label: const Text(
                'Calibrate New Zone',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: const Color(0xFF00D4FF).withOpacity(0.4)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CalibrationCard extends StatelessWidget {
  const _CalibrationCard({
    required this.name,
    required this.isActive,
    required this.roadCount,
    required this.footpathCount,
    required this.dividerCount,
    required this.sidelandCount,
    required this.onTap,
    required this.onDelete,
  });

  final String name;
  final bool isActive;
  final int roadCount;
  final int footpathCount;
  final int dividerCount;
  final int sidelandCount;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF12121A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive ? const Color(0xFF34C759) : Colors.white.withOpacity(0.05),
          width: isActive ? 1.5 : 1,
        ),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: const Color(0xFF34C759).withOpacity(0.12),
                  blurRadius: 10,
                  spreadRadius: 1,
                )
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Active marker indicator
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isActive ? const Color(0xFF34C759) : Colors.transparent,
                      border: Border.all(
                        color: isActive ? Colors.transparent : Colors.white24,
                        width: isActive ? 0 : 2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  
                  // Text details
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: isActive ? FontWeight.w700 : FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            _buildMiniChip('Road: $roadCount', const Color(0xFF00FF00)),
                            const SizedBox(width: 6),
                            _buildMiniChip('Path: $footpathCount', const Color(0xFFFF0000)),
                            const SizedBox(width: 6),
                            _buildMiniChip('Divider: $dividerCount', const Color(0xFF00D4FF)),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Delete button
                  IconButton(
                    onPressed: onDelete,
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.white.withOpacity(0.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMiniChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.2), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.withOpacity(0.8),
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
