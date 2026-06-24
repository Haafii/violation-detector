import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/violation_record.dart';
import '../services/violation_processor.dart';
import '../services/violation_storage_service.dart';

/// Violation history screen — rich card-based view of all saved violations.
class ViolationsHistoryScreen extends StatefulWidget {
  const ViolationsHistoryScreen({super.key});

  @override
  State<ViolationsHistoryScreen> createState() =>
      _ViolationsHistoryScreenState();
}

class _ViolationsHistoryScreenState extends State<ViolationsHistoryScreen> {
  final ViolationStorageService _storage = ViolationStorageService();
  List<ViolationRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    ViolationProcessor.instance.addListener(_onProcessorChange);
  }

  @override
  void dispose() {
    ViolationProcessor.instance.removeListener(_onProcessorChange);
    super.dispose();
  }

  void _onProcessorChange() {
    _load();
  }

  Future<void> _load() async {
    final records = await _storage.loadAll();
    if (mounted) setState(() { _records = records; _loading = false; });
  }

  Future<void> _clearAll() async {
    await _storage.clearAll();
    if (mounted) setState(() => _records.clear());
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
                  const Text('Violations',
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 22,
                          color: Colors.white,
                          letterSpacing: -0.5)),
                  Text('${_records.length} records',
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
              if (_records.isNotEmpty)
                IconButton(
                  onPressed: _showClearDialog,
                  icon: const Icon(Icons.delete_sweep_rounded,
                      color: Color(0xFFFF453A)),
                  tooltip: 'Clear All',
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
          else if (_records.isEmpty)
            SliverFillRemaining(child: _buildEmpty())
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _ViolationCard(
                      record: _records[i],
                      onTap: () => _showDetail(_records[i])),
                  childCount: _records.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(
            color: const Color(0xFF34C759).withOpacity(0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.verified_rounded,
              size: 40, color: const Color(0xFF34C759).withOpacity(0.6)),
        ),
        const SizedBox(height: 20),
        const Text('No violations recorded',
            style: TextStyle(
                color: Colors.white60,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Start detection to monitor traffic violations.',
            style: TextStyle(color: Colors.white30, fontSize: 13)),
      ]),
    );
  }

  void _showClearDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: const Text('Clear All Records',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: Text(
            'This will permanently delete all ${_records.length} violation records.',
            style: const TextStyle(color: Colors.white60)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white38))),
          TextButton(
              onPressed: () { Navigator.pop(ctx); _clearAll(); },
              child: const Text('Clear All',
                  style: TextStyle(
                      color: Color(0xFFFF453A), fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  void _showDetail(ViolationRecord record) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ViolationDetailSheet(record: record),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Violation Card (list item)
// ─────────────────────────────────────────────────────────────────────────────
class _ViolationCard extends StatefulWidget {
  const _ViolationCard({required this.record, required this.onTap});
  final ViolationRecord record;
  final VoidCallback onTap;

  @override
  State<_ViolationCard> createState() => _ViolationCardState();
}

class _ViolationCardState extends State<_ViolationCard> {
  ViolationRecord get record => widget.record;

  void _openGallery(List<String> paths, int initialIndex) {
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ImageGalleryViewer(
        imagePaths: paths,
        initialIndex: initialIndex,
        title: record.violationLabel,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(record.violationType);
    final timeStr = DateFormat('dd MMM yyyy  HH:mm:ss')
        .format(record.timestamp.toLocal());

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF111120),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withOpacity(0.22), width: 1.2),
          boxShadow: [
            BoxShadow(
                color: color.withOpacity(0.07),
                blurRadius: 20,
                offset: const Offset(0, 6)),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Snapshot image + plate strip ─────────────────────────────
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            child: _buildImageStrip(color),
          ),

          // ── Details ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Violation type badge + confidence
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: color.withOpacity(0.35)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_iconFor(record.violationType),
                          color: color, size: 13),
                      const SizedBox(width: 5),
                      Text(record.violationLabel,
                          style: TextStyle(
                              color: color,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.3)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${(record.violationConfidence * 100).round()}% conf',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11),
                    ),
                  ),
                  if (record.status == ViolationStatus.pending || record.status == ViolationStatus.processing) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00D4FF).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Color(0xFF00D4FF),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            record.status == ViolationStatus.pending ? 'Pending' : 'Processing',
                            style: const TextStyle(
                                color: Color(0xFF00D4FF),
                                fontSize: 11,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(record.vehicleClass,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11)),
                ]),
                const SizedBox(height: 10),

                // Plate number (highlighted)
                if (record.plateNumber != null && record.plateNumber!.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color(0xFF00D4FF).withOpacity(0.3)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.credit_card_rounded,
                          color: Color(0xFF00D4FF), size: 14),
                      const SizedBox(width: 8),
                      Text(record.plateNumber!,
                          style: const TextStyle(
                              color: Color(0xFF00D4FF),
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.5,
                              fontFamily: 'monospace')),
                      if (record.plateConfidence != null) ...[
                        const Spacer(),
                        Text(
                          '${(record.plateConfidence! * 100).round()}%',
                          style: const TextStyle(
                              color: Color(0xFF00D4FF), fontSize: 11),
                        ),
                      ],
                    ]),
                  )
                else if (record.status == ViolationStatus.pending || record.status == ViolationStatus.processing)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withOpacity(0.04),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.15)),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: Color(0xFF00D4FF),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          record.status == ViolationStatus.pending ? 'Queueing plate extraction...' : 'Extracting plate number...',
                          style: const TextStyle(
                            color: Color(0xFF00D4FF),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Time + metadata row
                Row(children: [
                  const Icon(Icons.schedule_rounded,
                      color: Colors.white30, size: 13),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(timeStr,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                  ),
                  if (record.zoneId != null && record.zoneId!.isNotEmpty)
                    Text('Zone: ${record.zoneId}',
                        style: const TextStyle(
                            color: Colors.white24, fontSize: 10)),
                ]),

                if (record.headingDeg != null) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.navigation_rounded,
                        color: Colors.white30, size: 13),
                    const SizedBox(width: 5),
                    Text(
                      'Heading ${record.headingDeg!.toStringAsFixed(1)}°'
                      '${record.legalHeadingDeg != null ? '  ·  Legal ${record.legalHeadingDeg!.toStringAsFixed(1)}°' : ''}',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildImageStrip(Color accentColor) {
    final hasVehicle = record.vehicleImagePath != null &&
        File(record.vehicleImagePath!).existsSync();
    final hasPlate = record.plateImagePath != null &&
        File(record.plateImagePath!).existsSync();
    final hasHelmet = record.helmetImagePath != null &&
        File(record.helmetImagePath!).existsSync();

    // Gather gallery images: vehicle first, then plate, then helmet
    final galleryPaths = <String>[
      if (hasVehicle)
        record.vehicleImagePath!
      else if (record.snapshotPath != null &&
          File(record.snapshotPath!).existsSync())
        record.snapshotPath!,
      if (hasPlate) record.plateImagePath!,
      if (hasHelmet) record.helmetImagePath!,
    ];

    return SizedBox(
      height: 160,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Vehicle crop
        Expanded(
          flex: 3,
          child: GestureDetector(
            onTap: galleryPaths.isNotEmpty
                ? () => _openGallery(galleryPaths, 0)
                : null,
            child: Stack(fit: StackFit.expand, children: [
              if (hasVehicle)
                Image.file(File(record.vehicleImagePath!), fit: BoxFit.cover)
              else if (record.snapshotPath != null &&
                  File(record.snapshotPath!).existsSync())
                Image.file(File(record.snapshotPath!), fit: BoxFit.cover)
              else
                Container(
                  color: accentColor.withOpacity(0.08),
                  child: Icon(_vehicleIcon(record.vehicleClass),
                      color: accentColor.withOpacity(0.3), size: 48),
                ),
              // Gradient overlay
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.6),
                    ],
                  ),
                ),
              ),
              // Tap hint icon
              if (galleryPaths.isNotEmpty)
                const Positioned(
                  top: 8, right: 8,
                  child: Icon(Icons.open_in_full_rounded,
                      color: Colors.white54, size: 16),
                ),
            ]),
          ),
        ),

        // Vertical divider
        Container(width: 2, color: const Color(0xFF080810)),

        // Plate crop
        Expanded(
          flex: 2,
          child: GestureDetector(
            onTap: hasPlate
                ? () => _openGallery(galleryPaths, galleryPaths.indexOf(record.plateImagePath!))
                : null,
            child: hasPlate
                ? Stack(fit: StackFit.expand, children: [
                    Image.file(File(record.plateImagePath!), fit: BoxFit.cover),
                    const Positioned(
                      top: 8, right: 8,
                      child: Icon(Icons.open_in_full_rounded,
                          color: Colors.white54, size: 14),
                    ),
                  ])
                : _buildPlatePlaceholder(accentColor),
          ),
        ),

        if (hasHelmet) ...[
          // Vertical divider
          Container(width: 2, color: const Color(0xFF080810)),

          // Helmet crop
          Expanded(
            flex: 2,
            child: GestureDetector(
              onTap: () => _openGallery(galleryPaths, galleryPaths.indexOf(record.helmetImagePath!)),
              child: Stack(fit: StackFit.expand, children: [
                Image.file(File(record.helmetImagePath!), fit: BoxFit.cover),
                const Positioned(
                  top: 8, right: 8,
                  child: Icon(Icons.open_in_full_rounded,
                      color: Colors.white54, size: 14),
                ),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _buildPlatePlaceholder(Color accentColor) {
    final isProcessing = record.status == ViolationStatus.pending || record.status == ViolationStatus.processing;
    return Container(
      color: const Color(0xFF080810),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isProcessing) ...[
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF00D4FF),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Processing...',
              style: TextStyle(
                  color: Color(0xFF00D4FF),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5),
              textAlign: TextAlign.center,
            ),
          ] else ...[
            Icon(Icons.credit_card_rounded,
                color: accentColor.withOpacity(0.25), size: 28),
            const SizedBox(height: 6),
            Text(
              record.plateNumber ?? 'No Plate',
              style: TextStyle(
                  color: accentColor.withOpacity(0.5),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  static IconData _vehicleIcon(String cls) {
    if (cls == 'motorcycle' || cls == 'two-wheeler') return Icons.two_wheeler_rounded;
    if (cls == 'truck' || cls == 'bus') return Icons.local_shipping_rounded;
    return Icons.directions_car_rounded;
  }

  static Color _colorFor(String type) => switch (type) {
        'wrong_side'       => const Color(0xFFFF453A),
        'footpath_driving' => const Color(0xFFFF9F0A),
        'no_helmet'        => const Color(0xFF30D158),
        _                  => const Color(0xFF00D4FF),
      };

  static IconData _iconFor(String type) => switch (type) {
        'wrong_side'       => Icons.swap_horiz_rounded,
        'footpath_driving' => Icons.directions_walk_rounded,
        'no_helmet'        => Icons.sports_motorsports_rounded,
        _                  => Icons.warning_rounded,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-detail bottom sheet
// ─────────────────────────────────────────────────────────────────────────────
class _ViolationDetailSheet extends StatelessWidget {
  const _ViolationDetailSheet({required this.record});
  final ViolationRecord record;

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(record.violationType);
    final timeStr = DateFormat('dd MMM yyyy  HH:mm:ss')
        .format(record.timestamp.toLocal());

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF10101E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: ListView(
          controller: controller,
          padding: EdgeInsets.zero,
          children: [
            // Handle
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10),
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),

            // ── Header ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(_iconFor(record.violationType),
                      color: color, size: 22),
                ),
                const SizedBox(width: 12),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(record.violationLabel,
                      style: TextStyle(
                          color: color,
                          fontSize: 18,
                          fontWeight: FontWeight.w800)),
                  Text('Track #${record.trackId}  ·  ${record.vehicleClass}',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12)),
                ]),
              ]),
            ),

            // ── Full frame snapshot ───────────────────────────────────
            if (record.snapshotPath != null &&
                File(record.snapshotPath!).existsSync()) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.file(
                    File(record.snapshotPath!),
                    height: 200,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ],

            // ── Plate chip ────────────────────────────────────────────
            _buildPlateSection(context, color),

            // ── Helmet chip ───────────────────────────────────────────
            _buildHelmetSection(context, color),

            // ── Info grid ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(title: 'Event Details', color: color),
                  const SizedBox(height: 10),
                  _DetailGrid(items: [
                    _GridItem('Event ID', record.eventId.split('_').take(2).join('_'), Icons.fingerprint_rounded),
                    _GridItem('Frame', '#${record.frameNumber}', Icons.videocam_rounded),
                    _GridItem('Date & Time', timeStr, Icons.calendar_today_rounded),
                    _GridItem('Zone', record.zoneId ?? '—', Icons.map_rounded),
                    _GridItem('Weather', record.weather, Icons.wb_sunny_rounded),
                    _GridItem('Congested', record.isCongested ? 'Yes' : 'No', Icons.traffic_rounded),
                  ]),
                  const SizedBox(height: 20),
                  _SectionTitle(title: 'Detection Metrics', color: color),
                  const SizedBox(height: 10),
                  _DetailGrid(items: [
                    _GridItem('Violation Conf.', '${(record.violationConfidence * 100).round()}%', Icons.analytics_rounded),
                    if (record.confidence != null)
                      _GridItem('Confidence', '${(record.confidence! * 100).round()}%', Icons.bar_chart_rounded),
                    if (record.headingDeg != null)
                      _GridItem('Heading', '${record.headingDeg!.toStringAsFixed(1)}°', Icons.navigation_rounded),
                    if (record.legalHeadingDeg != null)
                      _GridItem('Legal Heading', '${record.legalHeadingDeg!.toStringAsFixed(1)}°', Icons.navigation_outlined),
                    if (record.candidateFrames != null)
                      _GridItem('Candidate Frames', '${record.candidateFrames}', Icons.filter_frames_rounded),
                    if (record.bbox != null && record.bbox!.length >= 4)
                      _GridItem('BBox', '[${record.bbox!.map((v) => v.toStringAsFixed(0)).join(', ')}]', Icons.crop_rounded),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildPlateSection(BuildContext context, Color color) {
    if (record.plateNumber == null || record.plateNumber!.isEmpty) {
      return const SizedBox.shrink();
    }

    // Use stored plate image path directly
    Widget? plateImage;
    final hasPlateImage = record.plateImagePath != null &&
        File(record.plateImagePath!).existsSync();
    if (hasPlateImage) {
      plateImage = Image.file(File(record.plateImagePath!),
          height: 90, fit: BoxFit.contain);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF00D4FF).withOpacity(0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: const Color(0xFF00D4FF).withOpacity(0.25)),
        ),
        child: Row(children: [
          if (plateImage != null) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: plateImage,
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Number Plate',
                    style: TextStyle(
                        color: Color(0xFF00D4FF),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5)),
                const SizedBox(height: 6),
                Text(record.plateNumber!,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2.5,
                        fontFamily: 'monospace')),
                if (record.plateConfidence != null) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.analytics_rounded,
                        color: Color(0xFF00D4FF), size: 12),
                    const SizedBox(width: 4),
                    Text(
                      'OCR confidence: ${(record.plateConfidence! * 100).round()}%',
                      style: const TextStyle(
                          color: Color(0xFF00D4FF), fontSize: 11),
                    ),
                  ]),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildHelmetSection(BuildContext context, Color color) {
    final hasHelmetImage = record.helmetImagePath != null &&
        File(record.helmetImagePath!).existsSync();
    if (!hasHelmetImage) return const SizedBox.shrink();

    final helmetImage = Image.file(File(record.helmetImagePath!),
        height: 90, fit: BoxFit.contain);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFFF3B30).withOpacity(0.07),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: const Color(0xFFFF3B30).withOpacity(0.25)),
        ),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: helmetImage,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Helmet Detection',
                    style: TextStyle(
                        color: Color(0xFFFF3B30),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5)),
                const SizedBox(height: 6),
                const Text('NO HELMET',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0)),
                const SizedBox(height: 4),
                Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Color(0xFFFF3B30), size: 12),
                  const SizedBox(width: 4),
                  Text(
                      'Violation Confirmed',
                      style: TextStyle(
                          color: Colors.white.withOpacity(0.6),
                          fontSize: 11,
                          fontWeight: FontWeight.w500)),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  static Color _colorFor(String type) => switch (type) {
        'wrong_side'       => const Color(0xFFFF453A),
        'footpath_driving' => const Color(0xFFFF9F0A),
        'no_helmet'        => const Color(0xFF30D158),
        _                  => const Color(0xFF00D4FF),
      };

  static IconData _iconFor(String type) => switch (type) {
        'wrong_side'       => Icons.swap_horiz_rounded,
        'footpath_driving' => Icons.directions_walk_rounded,
        'no_helmet'        => Icons.sports_motorsports_rounded,
        _                  => Icons.warning_rounded,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.color});
  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 3, height: 14, color: color,
            margin: const EdgeInsets.only(right: 8)),
        Text(title,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5)),
      ]);
}

class _GridItem {
  const _GridItem(this.label, this.value, this.icon);
  final String label, value;
  final IconData icon;
}

class _DetailGrid extends StatelessWidget {
  const _DetailGrid({required this.items});
  final List<_GridItem> items;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: items.map((item) => _GridCell(item: item)).toList(),
      );
}

class _GridCell extends StatelessWidget {
  const _GridCell({required this.item});
  final _GridItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: (MediaQuery.of(context).size.width - 48) / 2,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(item.icon, color: Colors.white30, size: 12),
            const SizedBox(width: 5),
            Text(item.label,
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 5),
          Text(item.value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Full-screen image gallery viewer
// ─────────────────────────────────────────────────────────────────────────────
class _ImageGalleryViewer extends StatefulWidget {
  const _ImageGalleryViewer({
    required this.imagePaths,
    required this.title,
    this.initialIndex = 0,
  });

  final List<String> imagePaths;
  final String title;
  final int initialIndex;

  @override
  State<_ImageGalleryViewer> createState() => _ImageGalleryViewerState();
}

class _ImageGalleryViewerState extends State<_ImageGalleryViewer> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = _buildLabels();

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.5),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
            if (labels.isNotEmpty)
              Text(labels[_currentIndex],
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12)),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(children: [
        // ── Main swipeable image view ────────────────────────────────────
        PageView.builder(
          controller: _pageController,
          itemCount: widget.imagePaths.length,
          onPageChanged: (i) => setState(() => _currentIndex = i),
          itemBuilder: (context, index) {
            final path = widget.imagePaths[index];
            final file = File(path);
            if (!file.existsSync()) {
              return const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.broken_image_rounded,
                        color: Colors.white24, size: 56),
                    SizedBox(height: 12),
                    Text('Image not found',
                        style: TextStyle(color: Colors.white30)),
                  ],
                ),
              );
            }
            return InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              child: Center(
                child: Image.file(file, fit: BoxFit.contain),
              ),
            );
          },
        ),

        // ── Page indicator dots ──────────────────────────────────────────
        if (widget.imagePaths.length > 1)
          Positioned(
            bottom: 40,
            left: 0, right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(widget.imagePaths.length, (i) {
                final isActive = i == _currentIndex;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: isActive ? 20 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isActive
                        ? const Color(0xFF00D4FF)
                        : Colors.white30,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),

        // ── Image label at bottom ────────────────────────────────────────
        if (labels.isNotEmpty)
          Positioned(
            bottom: 60,
            left: 0, right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  labels[_currentIndex],
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
          ),

        // ── Swipe hint arrows (for multi-image) ──────────────────────────
        if (widget.imagePaths.length > 1) ...[
          if (_currentIndex > 0)
            Positioned(
              left: 12,
              top: 0, bottom: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () => _pageController.previousPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.chevron_left_rounded,
                        color: Colors.white70, size: 28),
                  ),
                ),
              ),
            ),
          if (_currentIndex < widget.imagePaths.length - 1)
            Positioned(
              right: 12,
              top: 0, bottom: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () => _pageController.nextPage(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.chevron_right_rounded,
                        color: Colors.white70, size: 28),
                  ),
                ),
              ),
            ),
        ],
      ]),
    );
  }

  List<String> _buildLabels() {
    if (widget.imagePaths.length == 1) return [''];
    return [
      for (var i = 0; i < widget.imagePaths.length; i++)
        i == 0 ? '🚗 Vehicle' : '🪪 Number Plate',
    ];
  }
}
