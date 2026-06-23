import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../fsm/fsm_state.dart';
import '../fsm/zone_topology.dart';

class ManualPolygonScreen extends StatefulWidget {
  const ManualPolygonScreen({
    super.key,
    required this.backgroundImage,
    required this.frameWidth,
    required this.frameHeight,
  });

  final Uint8List backgroundImage;
  final double frameWidth;
  final double frameHeight;

  @override
  State<ManualPolygonScreen> createState() => _ManualPolygonScreenState();
}

class _ManualPolygonScreenState extends State<ManualPolygonScreen> {
  final List<Zone> _savedZones = [];
  final List<Offset> _currentPoints = [];
  ZoneType _selectedType = ZoneType.road;
  int _zoneCounter = 1;

  void _addPoint(Offset point, double scaleX, double scaleY) {
    // Convert from display space back to image space
    final imgX = point.dx / scaleX;
    final imgY = point.dy / scaleY;

    // Clamp to bounds
    final clampedX = imgX.clamp(0.0, widget.frameWidth);
    final clampedY = imgY.clamp(0.0, widget.frameHeight);

    setState(() {
      _currentPoints.add(Offset(clampedX, clampedY));
    });
  }

  void _undoPoint() {
    if (_currentPoints.isNotEmpty) {
      setState(() {
        _currentPoints.removeLast();
      });
    }
  }

  void _clearCurrent() {
    setState(() {
      _currentPoints.clear();
    });
  }

  void _saveCurrentZone() {
    if (_currentPoints.length < 3) return;

    final zoneId = '${_selectedType.name}_manual_${_zoneCounter++}';
    final newZone = Zone(
      zoneId: zoneId,
      zoneType: _selectedType,
      polygon: List.from(_currentPoints),
      legalHeadingDeg: 0.0,
      headingToleranceDeg: 40.0,
      vehicleClasses: const ['all'],
      needsManualHeading: false,
    );

    setState(() {
      _savedZones.add(newZone);
      _currentPoints.clear();
    });
  }

  void _deleteZone(int index) {
    setState(() {
      _savedZones.removeAt(index);
    });
  }

  void _finish() {
    Navigator.pop(context, ZoneTopology(zones: _savedZones));
  }

  Color _getColorForType(ZoneType type) {
    switch (type) {
      case ZoneType.road:
        return const Color(0xFF00D4FF);
      case ZoneType.footpath:
        return const Color(0xFF34C759);
      case ZoneType.divider:
        return const Color(0xFFFF3B30);
      case ZoneType.sideland:
        return const Color(0xFFAF52DE);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0E),
      body: SafeArea(
        child: Column(
          children: [
            // Top Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Manual Calibration',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close, color: Colors.white60, size: 18),
                        label: const Text('Cancel', style: TextStyle(color: Colors.white60)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Draw polygons on the screen to define camera zones.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            // Main camera view with drawing overlay
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: Stack(
                        children: [
                          // Background frozen JPEG frame
                          Positioned.fill(
                            child: Image.memory(
                              widget.backgroundImage,
                              fit: BoxFit.cover,
                            ),
                          ),

                          // Custom Painter for drawing
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                final sz = constraints.biggest;
                                final scaleX = sz.width / widget.frameWidth;
                                final scaleY = sz.height / widget.frameHeight;

                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) {
                                    _addPoint(details.localPosition, scaleX, scaleY);
                                  },
                                  child: CustomPaint(
                                    size: sz,
                                    painter: PolygonDrawPainter(
                                      savedZones: _savedZones,
                                      currentPoints: _currentPoints,
                                      selectedType: _selectedType,
                                      scaleX: scaleX,
                                      scaleY: scaleY,
                                      activeColor: _getColorForType(_selectedType),
                                      colorMapper: _getColorForType,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Bottom Actions & Selectors
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Zone Type Selection Chips
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: ZoneType.values.map((type) {
                      final isSelected = _selectedType == type;
                      final typeColor = _getColorForType(type);
                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _selectedType = type;
                          });
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isSelected ? typeColor.withOpacity(0.18) : const Color(0xFF1E1E26),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? typeColor : Colors.white.withOpacity(0.04),
                              width: 1.5,
                            ),
                          ),
                          child: Text(
                            type.name.toUpperCase(),
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white.withOpacity(0.6),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),

                  // Point Control Buttons (Undo, Clear, Save)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _currentPoints.isNotEmpty ? _undoPoint : null,
                        icon: const Icon(Icons.undo, size: 16),
                        label: const Text('Undo'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          disabledForegroundColor: Colors.white24,
                          side: BorderSide(color: Colors.white.withOpacity(0.12)),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _currentPoints.isNotEmpty ? _clearCurrent : null,
                        icon: const Icon(Icons.clear_all, size: 16),
                        label: const Text('Clear'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          disabledForegroundColor: Colors.white24,
                          side: BorderSide(color: Colors.white.withOpacity(0.12)),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _currentPoints.length >= 3 ? _saveCurrentZone : null,
                        icon: const Icon(Icons.check, size: 16),
                        label: const Text('Save Zone'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _getColorForType(_selectedType),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.white10,
                          disabledForegroundColor: Colors.white24,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Display Saved Zones Count / List Summary
                  if (_savedZones.isNotEmpty)
                    Container(
                      height: 50,
                      margin: const EdgeInsets.only(bottom: 16),
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _savedZones.length,
                        itemBuilder: (context, index) {
                          final zone = _savedZones[index];
                          return Container(
                            margin: const EdgeInsets.only(right: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E1E26),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: _getColorForType(zone.zoneType).withOpacity(0.3)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 4,
                                  backgroundColor: _getColorForType(zone.zoneType),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${zone.zoneType.name} #${index + 1} (${zone.polygon.length} pts)',
                                  style: const TextStyle(color: Colors.white, fontSize: 11),
                                ),
                                const SizedBox(width: 4),
                                GestureDetector(
                                  onTap: () => _deleteZone(index),
                                  child: const Icon(Icons.delete, color: Colors.redAccent, size: 14),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),

                  // Start Detection Button
                  ElevatedButton(
                    onPressed: _savedZones.isNotEmpty ? _finish : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00D4FF),
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.white10,
                      disabledForegroundColor: Colors.white24,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text(
                      'Done & Auto-Detect Directions',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PolygonDrawPainter extends CustomPainter {
  PolygonDrawPainter({
    required this.savedZones,
    required this.currentPoints,
    required this.selectedType,
    required this.scaleX,
    required this.scaleY,
    required this.activeColor,
    required this.colorMapper,
  });

  final List<Zone> savedZones;
  final List<Offset> currentPoints;
  final ZoneType selectedType;
  final double scaleX;
  final double scaleY;
  final Color activeColor;
  final Color Function(ZoneType) colorMapper;

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Draw saved zones
    for (final zone in savedZones) {
      if (zone.polygon.isEmpty) continue;
      final zoneColor = colorMapper(zone.zoneType);

      final paint = Paint()
        ..color = zoneColor.withOpacity(0.12)
        ..style = PaintingStyle.fill;

      final borderPaint = Paint()
        ..color = zoneColor
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke;

      final path = Path();
      path.moveTo(zone.polygon[0].dx * scaleX, zone.polygon[0].dy * scaleY);
      for (int i = 1; i < zone.polygon.length; i++) {
        path.lineTo(zone.polygon[i].dx * scaleX, zone.polygon[i].dy * scaleY);
      }
      path.close();

      canvas.drawPath(path, paint);
      canvas.drawPath(path, borderPaint);
    }

    // 2. Draw current in-progress points and lines
    if (currentPoints.isNotEmpty) {
      final pointPaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.fill;

      final linePaint = Paint()
        ..color = activeColor
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;

      // Draw lines connecting points
      if (currentPoints.length > 1) {
        final path = Path();
        path.moveTo(currentPoints[0].dx * scaleX, currentPoints[0].dy * scaleY);
        for (int i = 1; i < currentPoints.length; i++) {
          path.lineTo(currentPoints[i].dx * scaleX, currentPoints[i].dy * scaleY);
        }
        canvas.drawPath(path, linePaint);
      }

      // Draw all points as circles
      for (final pt in currentPoints) {
        canvas.drawCircle(Offset(pt.dx * scaleX, pt.dy * scaleY), 5.0, pointPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PolygonDrawPainter oldDelegate) {
    return oldDelegate.savedZones != savedZones ||
        oldDelegate.currentPoints != currentPoints ||
        oldDelegate.selectedType != selectedType ||
        oldDelegate.scaleX != scaleX ||
        oldDelegate.scaleY != scaleY;
  }
}
