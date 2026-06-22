import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../fsm/fsm_state.dart';
import '../fsm/zone_topology.dart';
import '../services/violation_storage_service.dart';
import 'detection_screen.dart';

// ── Zone type colours (matches Python calibrate.py) ──────────────────────────
const _kRoadColor      = Color(0xFF00FF00); // green
const _kFootpathColor  = Color(0xFFFF0000); // red
const _kSidelandColor  = Color(0xFFFFFF00); // yellow

Color _zoneColor(ZoneType t) {
  switch (t) {
    case ZoneType.road:      return _kRoadColor;
    case ZoneType.footpath:  return _kFootpathColor;
    case ZoneType.sideland:  return _kSidelandColor;
    case ZoneType.divider:   return Colors.cyan;
  }
}

// ── Interaction mode ─────────────────────────────────────────────────────────
enum _Mode { polygon, arrow }

// ── Internal zone being built ─────────────────────────────────────────────────
class _DraftZone {
  _DraftZone({required this.zoneType, required this.name, required this.polygon});
  ZoneType zoneType;
  String name;
  List<Offset> polygon;
  Offset? arrowTail;
  Offset? arrowTip;
  double? legalHeadingDeg;
}

/// Calibration screen — triggered from "Start Detection".
///
/// Flow (mirrors tools/calibrate.py exactly):
///   1. Grab first camera frame, freeze it as background.
///   2. User taps to draw polygon vertices.
///   3. "Finish Zone" → choose zone type + name (bottom sheet).
///   4. For Road zones → tap 2 arrow points (tail, tip) to set legal heading.
///   5. Repeat for more zones.
///   6. "Start Detection" → saves topology → pushes DetectionScreen.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  // ── Camera ──────────────────────────────────────────────────────────────────
  CameraController? _camCtrl;
  bool _loadingFrame = true;
  String? _loadError;

  // ── First frame as image ────────────────────────────────────────────────────
  ui.Image? _bgImage;
  Uint8List? _bgBytes; // JPEG for saving
  double _imgW = 1.0, _imgH = 1.0;

  // ── Drawing state ────────────────────────────────────────────────────────────
  _Mode _mode = _Mode.polygon;
  List<Offset> _currentPts = [];      // vertices for current polygon in progress
  List<Offset> _arrowPts  = [];       // max 2 points for direction arrow
  final List<_DraftZone> _zones = [];
  _DraftZone? _pendingRoadZone;       // road zone waiting for arrow input

  final _storage = ViolationStorageService();

  // ── Canvas transform (image → screen) ───────────────────────────────────────
  // We fit the image inside the canvas; track the offset & scale.
  double _fitScale = 1.0;
  Offset _fitOffset = Offset.zero;
  late Size _canvasSize;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _camCtrl?.dispose();
    super.dispose();
  }

  // ── Camera init & first-frame grab ──────────────────────────────────────────

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) setState(() { _loadError = 'No camera found.'; _loadingFrame = false; });
      return;
    }
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back && c.name == '0',
      orElse: () => cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      ),
    );
    final ctrl = CameraController(back, ResolutionPreset.veryHigh, enableAudio: false);
    _camCtrl = ctrl;
    try {
      await ctrl.initialize();
      final xfile = await ctrl.takePicture();
      final bytes = await xfile.readAsBytes();
      await ctrl.dispose();
      _camCtrl = null;

      // Decode to ui.Image for display
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final uiImg = frame.image;

      if (mounted) {
        setState(() {
          _bgImage  = uiImg;
          _bgBytes  = bytes;
          _imgW     = uiImg.width.toDouble();
          _imgH     = uiImg.height.toDouble();
          _loadingFrame = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loadError = 'Camera error: $e'; _loadingFrame = false; });
    }
  }

  // ── Coordinate helpers ───────────────────────────────────────────────────────

  /// Convert tap position (in canvas) → image pixel coords.
  Offset _screenToImage(Offset screen) {
    return Offset(
      ((screen.dx - _fitOffset.dx) / _fitScale).clamp(0, _imgW),
      ((screen.dy - _fitOffset.dy) / _fitScale).clamp(0, _imgH),
    );
  }

  /// Convert image pixel coords → canvas position.
  Offset _imageToScreen(Offset img) {
    return Offset(img.dx * _fitScale + _fitOffset.dx,
                  img.dy * _fitScale + _fitOffset.dy);
  }

  void _updateFitTransform(Size canvasSize) {
    _canvasSize = canvasSize;
    final scaleX = canvasSize.width  / _imgW;
    final scaleY = canvasSize.height / _imgH;
    _fitScale  = math.min(scaleX, scaleY);
    _fitOffset = Offset(
      (canvasSize.width  - _imgW * _fitScale) / 2,
      (canvasSize.height - _imgH * _fitScale) / 2,
    );
  }

  // ── Tap handlers ─────────────────────────────────────────────────────────────

  void _onTap(TapDownDetails d) {
    if (_bgImage == null) return;
    final imgPt = _screenToImage(d.localPosition);

    if (_mode == _Mode.polygon) {
      setState(() => _currentPts.add(imgPt));
    } else if (_mode == _Mode.arrow && _arrowPts.length < 2) {
      setState(() {
        _arrowPts.add(imgPt);
        if (_arrowPts.length == 2) _finaliseArrow();
      });
    }
  }

  void _undoLastPoint() {
    if (_mode == _Mode.polygon && _currentPts.isNotEmpty) {
      setState(() => _currentPts.removeLast());
    } else if (_mode == _Mode.arrow && _arrowPts.isNotEmpty) {
      setState(() => _arrowPts.removeLast());
    }
  }

  // ── Zone completion ──────────────────────────────────────────────────────────

  Future<void> _finishPolygon() async {
    if (_currentPts.length < 3) {
      _snack('Need at least 3 points.');
      return;
    }
    final polygon = List<Offset>.from(_currentPts);
    await _showZoneTypeSheet(polygon);
  }

  Future<void> _showZoneTypeSheet(List<Offset> polygon) async {
    ZoneType? chosen;
    String zoneName = 'zone_${_zones.length + 1}';

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1C28),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Zone Type', style: TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            // Name field
            TextField(
              decoration: InputDecoration(
                labelText: 'Zone name',
                labelStyle: const TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              style: const TextStyle(color: Colors.white),
              onChanged: (v) => zoneName = v.trim().isEmpty ? zoneName : v.trim(),
            ),
            const SizedBox(height: 16),
            // Type chips
            Row(children: ZoneType.values.map((zt) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(zt.name, style: const TextStyle(fontSize: 13)),
                selected: chosen == zt,
                onSelected: (_) => setS(() => chosen = zt),
                selectedColor: _zoneColor(zt).withOpacity(0.35),
                backgroundColor: Colors.white10,
                side: BorderSide(color: _zoneColor(zt).withOpacity(0.5)),
                labelStyle: TextStyle(
                    color: chosen == zt ? _zoneColor(zt) : Colors.white54,
                    fontWeight: FontWeight.w600),
              ),
            )).toList()),
            const SizedBox(height: 20),
            SizedBox(width: double.infinity,
              child: ElevatedButton(
                onPressed: chosen == null ? null : () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0080FF),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Confirm Zone',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        );
      }),
    );

    if (chosen == null) return;

    final draft = _DraftZone(zoneType: chosen!, name: zoneName, polygon: polygon);
    setState(() {
      _currentPts.clear();
      if (chosen == ZoneType.road) {
        // Switch to arrow mode for direction picking
        _pendingRoadZone = draft;
        _arrowPts.clear();
        _mode = _Mode.arrow;
        _snack('Tap 2 points: arrow TAIL then TIP (legal direction)');
      } else {
        _zones.add(draft);
      }
    });
  }

  void _finaliseArrow() {
    if (_arrowPts.length < 2 || _pendingRoadZone == null) return;
    final p1 = _arrowPts[0], p2 = _arrowPts[1];
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final headingDeg = math.atan2(dy, dx) * 180 / math.pi;

    _pendingRoadZone!.arrowTail = p1;
    _pendingRoadZone!.arrowTip  = p2;
    _pendingRoadZone!.legalHeadingDeg = headingDeg;

    setState(() {
      _zones.add(_pendingRoadZone!);
      _pendingRoadZone = null;
      _mode = _Mode.polygon;
      _arrowPts.clear();
    });
    _snack('Road zone added. Legal heading: ${headingDeg.toStringAsFixed(1)}°');
  }

  // ── Save & go ────────────────────────────────────────────────────────────────

  Future<void> _startDetection() async {
    if (_zones.isEmpty) {
      _snack('Draw at least one zone first.');
      return;
    }

    // Map photo coordinates (imgW x imgH) to target 9:16 aspect ratio crop.
    const targetAspect = 9 / 16;
    final photoAspect = _imgW / _imgH;

    double croppedW = _imgW;
    double croppedH = _imgH;
    double offsetX = 0.0;
    double offsetY = 0.0;

    if (photoAspect > targetAspect) {
      // Photo is wider than target (e.g. 3:4 vs 9:16)
      croppedW = _imgH * targetAspect;
      offsetX = (_imgW - croppedW) / 2;
    } else if (photoAspect < targetAspect) {
      // Photo is taller than target
      croppedH = _imgW / targetAspect;
      offsetY = (_imgH - croppedH) / 2;
    }

    Offset mapCoords(Offset p) {
      // Normalize coordinate within the cropped viewport (0.0 to 1.0)
      return Offset(
        (p.dx - offsetX) / croppedW,
        (p.dy - offsetY) / croppedH,
      );
    }

    // Build ZoneTopology from draft zones (coordinates are normalized 0.0 to 1.0)
    final topology = ZoneTopology(zones: _zones.map((d) => Zone(
      zoneId: d.name,
      zoneType: d.zoneType,
      polygon: d.polygon.map(mapCoords).toList(),
      legalHeadingDeg: d.legalHeadingDeg ?? 90.0,
      headingToleranceDeg: 30.0,
    )).toList());

    await _storage.saveTopology(topology.toJson());

    if (!mounted) return;
    await Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => DetectionScreen(topology: topology, frameBytes: _bgBytes),
      ),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // ── Canvas ────────────────────────────────────────────────────────────
        if (_loadingFrame)
          const Center(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Color(0xFF00D4FF)),
              SizedBox(height: 16),
              Text('Capturing first frame…',
                  style: TextStyle(color: Colors.white70)),
            ],
          ))
        else if (_loadError != null)
          Center(child: Text(_loadError!, style: const TextStyle(color: Colors.red)))
        else
          LayoutBuilder(builder: (ctx, constraints) {
            _updateFitTransform(constraints.biggest);
            return GestureDetector(
              onTapDown: _onTap,
              child: CustomPaint(
                size: constraints.biggest,
                painter: _CalibPainter(
                  bgImage: _bgImage,
                  zones: _zones,
                  currentPts: _currentPts,
                  arrowPts: _arrowPts,
                  mode: _mode,
                  pendingZone: _pendingRoadZone,
                  fitScale: _fitScale,
                  fitOffset: _fitOffset,
                  imgW: _imgW, imgH: _imgH,
                ),
              ),
            );
          }),

        // ── Top HUD ───────────────────────────────────────────────────────────
        if (!_loadingFrame && _loadError == null)
          SafeArea(child: _buildTopHud()),

        // ── Bottom toolbar ────────────────────────────────────────────────────
        if (!_loadingFrame && _loadError == null)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _buildBottomBar(),
          ),
      ]),
    );
  }

  Widget _buildTopHud() {
    final modeLabel = _mode == _Mode.polygon
        ? (_pendingRoadZone == null
            ? 'TAP to add polygon points'
            : 'ARROW: tap tail, then tip')
        : 'TAP 2 points for direction (${_arrowPts.length}/2)';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: Colors.black54, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                color: Colors.white, size: 18),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.65),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(modeLabel,
                style: TextStyle(
                  color: _mode == _Mode.arrow
                      ? const Color(0xFFFFCC00) : Colors.white,
                  fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(width: 10),
        // Zones counter badge
        if (_zones.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF00D4FF).withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF00D4FF).withOpacity(0.4)),
            ),
            child: Text('${_zones.length} zones',
                style: const TextStyle(
                    color: Color(0xFF00D4FF), fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
      ]),
    );
  }

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter, end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.9), Colors.transparent]),
      ),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: SafeArea(
        top: false,
        child: Row(children: [
          // Undo
          _ToolBtn(
            icon: Icons.undo_rounded, label: 'Undo',
            color: Colors.orange, onTap: _undoLastPoint,
          ),
          const SizedBox(width: 10),
          // Finish Zone (polygon mode only, ≥3 pts)
          if (_mode == _Mode.polygon) ...[
            Expanded(child: _ToolBtn(
              icon: Icons.check_circle_outline_rounded,
              label: 'Finish Zone (${_currentPts.length} pts)',
              color: _currentPts.length >= 3
                  ? const Color(0xFF34C759) : Colors.grey,
              onTap: _currentPts.length >= 3 ? _finishPolygon : null,
            )),
          ] else ...[
            Expanded(child: _ToolBtn(
              icon: Icons.arrow_forward_rounded,
              label: 'Set Direction (${_arrowPts.length}/2)',
              color: const Color(0xFFFFCC00),
              onTap: null,
            )),
          ],
          const SizedBox(width: 10),
          // Start Detection (only when zones exist)
          if (_zones.isNotEmpty && _mode == _Mode.polygon)
            Expanded(child: ElevatedButton.icon(
              onPressed: _startDetection,
              icon: const Icon(Icons.videocam_rounded, size: 18),
              label: const Text('Start Detection'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0080FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            )),
        ]),
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }
}

// ── CustomPainter ─────────────────────────────────────────────────────────────

class _CalibPainter extends CustomPainter {
  _CalibPainter({
    required this.bgImage,
    required this.zones,
    required this.currentPts,
    required this.arrowPts,
    required this.mode,
    required this.pendingZone,
    required this.fitScale,
    required this.fitOffset,
    required this.imgW,
    required this.imgH,
  });

  final ui.Image? bgImage;
  final List<_DraftZone> zones;
  final List<Offset> currentPts;
  final List<Offset> arrowPts;
  final _Mode mode;
  final _DraftZone? pendingZone;
  final double fitScale, imgW, imgH;
  final Offset fitOffset;

  Offset _i2s(Offset p) =>
      Offset(p.dx * fitScale + fitOffset.dx, p.dy * fitScale + fitOffset.dy);

  @override
  void paint(Canvas canvas, Size size) {
    // ── Background image ─────────────────────────────────────────────────────
    if (bgImage != null) {
      final src = Rect.fromLTWH(0, 0, imgW, imgH);
      final dst = Rect.fromLTWH(fitOffset.dx, fitOffset.dy,
          imgW * fitScale, imgH * fitScale);
      canvas.drawImageRect(bgImage!, src, dst, Paint());
    }

    // ── Saved zones ──────────────────────────────────────────────────────────
    for (final z in zones) {
      _drawZone(canvas, z.polygon, _zoneColor(z.zoneType), z.name);
      if (z.arrowTail != null && z.arrowTip != null) {
        _drawArrow(canvas, _i2s(z.arrowTail!), _i2s(z.arrowTip!));
      }
    }

    // ── Pending road zone (waiting for arrow) ────────────────────────────────
    if (pendingZone != null) {
      _drawZone(canvas, pendingZone!.polygon,
          _zoneColor(pendingZone!.zoneType), pendingZone!.name);
    }

    // ── Current in-progress polygon ──────────────────────────────────────────
    if (currentPts.isNotEmpty) {
      final sPts = currentPts.map(_i2s).toList();
      final paint = Paint()
        ..color = Colors.white.withOpacity(0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round;
      if (sPts.length >= 2) {
        final path = Path()..moveTo(sPts.first.dx, sPts.first.dy);
        for (final p in sPts.skip(1)) path.lineTo(p.dx, p.dy);
        canvas.drawPath(path, paint);
        // Closing dashed hint
        if (sPts.length >= 3) {
          canvas.drawLine(sPts.last, sPts.first,
              paint..color = Colors.white38);
        }
      }
      // Vertices
      for (final p in sPts) {
        canvas.drawCircle(p, 5,
            Paint()..color = Colors.white..style = PaintingStyle.fill);
        canvas.drawCircle(p, 5,
            Paint()..color = Colors.black26..style = PaintingStyle.stroke..strokeWidth = 1);
      }
    }

    // ── Arrow points ─────────────────────────────────────────────────────────
    if (mode == _Mode.arrow) {
      const arrowColor = Color(0xFFFFCC00);
      for (int i = 0; i < arrowPts.length; i++) {
        final sp = _i2s(arrowPts[i]);
        canvas.drawCircle(sp, 7,
            Paint()..color = arrowColor..style = PaintingStyle.fill);
        final label = i == 0 ? 'TAIL' : 'TIP';
        _drawLabel(canvas, sp + const Offset(10, -10), label, arrowColor);
      }
      if (arrowPts.length == 2) {
        _drawArrow(canvas, _i2s(arrowPts[0]), _i2s(arrowPts[1]));
      }
    }
  }

  void _drawZone(Canvas canvas, List<Offset> pts, Color color, String label) {
    if (pts.length < 3) return;
    final sPts = pts.map(_i2s).toList();
    final path = Path()..moveTo(sPts.first.dx, sPts.first.dy);
    for (final p in sPts.skip(1)) path.lineTo(p.dx, p.dy);
    path.close();

    // Semi-transparent fill
    canvas.drawPath(path, Paint()..color = color.withOpacity(0.20));
    // Outline
    canvas.drawPath(path, Paint()
      ..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
    // Label at centroid
    final cx = sPts.map((p) => p.dx).reduce((a, b) => a + b) / sPts.length;
    final cy = sPts.map((p) => p.dy).reduce((a, b) => a + b) / sPts.length;
    _drawLabel(canvas, Offset(cx, cy), label, color);
  }

  void _drawArrow(Canvas canvas, Offset tail, Offset tip) {
    const color = Color(0xFFFFC800);
    final paint = Paint()..color = color..strokeWidth = 2.5..strokeCap = StrokeCap.round;
    canvas.drawLine(tail, tip, paint);

    // Arrowhead
    const headLen = 14.0;
    const headAngle = 0.45;
    final angle = math.atan2(tip.dy - tail.dy, tip.dx - tail.dx);
    final p1 = Offset(
        tip.dx - headLen * math.cos(angle - headAngle),
        tip.dy - headLen * math.sin(angle - headAngle));
    final p2 = Offset(
        tip.dx - headLen * math.cos(angle + headAngle),
        tip.dy - headLen * math.sin(angle + headAngle));
    final head = Path()..moveTo(tip.dx, tip.dy)..lineTo(p1.dx, p1.dy)..lineTo(p2.dx, p2.dy)..close();
    canvas.drawPath(head, Paint()..color = color);
  }

  void _drawLabel(Canvas canvas, Offset pos, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 11,
            fontWeight: FontWeight.w700,
            shadows: const [Shadow(color: Colors.black, blurRadius: 4)]),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_CalibPainter old) => true;
}

// ── Small toolbar button widget ───────────────────────────────────────────────

class _ToolBtn extends StatelessWidget {
  const _ToolBtn({required this.icon, required this.label,
      required this.color, required this.onTap});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Flexible(child: Text(label,
                style: TextStyle(color: color, fontSize: 11,
                    fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis)),
          ]),
        ),
      ),
    );
  }
}
