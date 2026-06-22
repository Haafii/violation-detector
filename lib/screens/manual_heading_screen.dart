import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../fsm/fsm_state.dart';
import '../fsm/zone_topology.dart';

// Zone colours – mirror calibration_screen.dart
Color _zoneColor(ZoneType t) {
  switch (t) {
    case ZoneType.road:      return const Color(0xFF00FF00);
    case ZoneType.footpath:  return const Color(0xFFFF0000);
    case ZoneType.sideland:  return const Color(0xFFFFFF00);
    case ZoneType.divider:   return Colors.cyan;
  }
}

class ManualHeadingScreen extends StatefulWidget {
  const ManualHeadingScreen({
    super.key,
    required this.flaggedZones,
    required this.allZones,
    required this.backgroundImage,
    required this.frameWidth,
    required this.frameHeight,
  });

  /// Road zones that still need a manual heading (iterated one by one).
  final List<Zone> flaggedZones;

  /// All zones (including non-road ones) so we can write back a full topology.
  final List<Zone> allZones;

  /// Portrait JPEG of the frozen camera frame.
  final Uint8List backgroundImage;

  /// Width / height of the camera frame in pixels (portrait).
  final double frameWidth;
  final double frameHeight;

  @override
  State<ManualHeadingScreen> createState() => _ManualHeadingScreenState();
}

class _ManualHeadingScreenState extends State<ManualHeadingScreen> {
  // ── Zone iteration ──────────────────────────────────────────────────────────
  int _currentIndex = 0;
  final Map<String, _ArrowResult> _resolvedArrows = {};

  // ── 2-tap arrow state for the current zone ──────────────────────────────────
  /// Points in *image pixel* space: [tail, tip] (max 2).
  final List<Offset> _arrowPts = [];

  // ── Background image (decoded once for the painter) ─────────────────────────
  ui.Image? _bgImage;
  bool _imageReady = false;

  // ── Canvas fit transform ─────────────────────────────────────────────────────
  double _fitScale = 1.0;
  Offset _fitOffset = Offset.zero;

  @override
  void initState() {
    super.initState();
    _decodeBgImage();
  }

  Future<void> _decodeBgImage() async {
    final codec = await ui.instantiateImageCodec(widget.backgroundImage);
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() {
        _bgImage = frame.image;
        _imageReady = true;
      });
    }
  }

  // ── Fit transform helpers ────────────────────────────────────────────────────
  void _updateFit(Size canvasSize) {
    final scaleX = canvasSize.width  / widget.frameWidth;
    final scaleY = canvasSize.height / widget.frameHeight;
    _fitScale  = math.min(scaleX, scaleY);
    _fitOffset = Offset(
      (canvasSize.width  - widget.frameWidth  * _fitScale) / 2,
      (canvasSize.height - widget.frameHeight * _fitScale) / 2,
    );
  }

  /// Canvas → image-pixel coordinates.
  Offset _screenToImage(Offset screen) => Offset(
        ((screen.dx - _fitOffset.dx) / _fitScale).clamp(0, widget.frameWidth),
        ((screen.dy - _fitOffset.dy) / _fitScale).clamp(0, widget.frameHeight),
      );

  // ── Tap handler ──────────────────────────────────────────────────────────────
  void _onTap(TapDownDetails d) {
    if (_arrowPts.length >= 2) return; // already have both points

    final imgPt = _screenToImage(d.localPosition);
    setState(() {
      _arrowPts.add(imgPt);
      if (_arrowPts.length == 2) {
        _finaliseArrow();
      }
    });
  }

  void _undoLastPoint() {
    if (_arrowPts.isEmpty) return;
    setState(() => _arrowPts.removeLast());
  }

  // ── Arrow finalisation ───────────────────────────────────────────────────────
  void _finaliseArrow() {
    if (_arrowPts.length < 2) return;
    final tail = _arrowPts[0];
    final tip  = _arrowPts[1];
    final dx   = tip.dx - tail.dx;
    final dy   = tip.dy - tail.dy;
    final headingDeg = math.atan2(dy, dx) * 180 / math.pi;

    final currentZone = widget.flaggedZones[_currentIndex];
    _resolvedArrows[currentZone.zoneId] = _ArrowResult(
      tail: tail,
      tip:  tip,
      headingDeg: headingDeg,
    );

    _showSnack(
      'Zone "${currentZone.zoneId}": heading = ${headingDeg.toStringAsFixed(1)}°',
    );

    // Advance automatically after a short pause so the user sees the arrow
    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _advance();
    });
  }

  // ── Navigation ───────────────────────────────────────────────────────────────
  void _advance() {
    if (_currentIndex < widget.flaggedZones.length - 1) {
      setState(() {
        _currentIndex++;
        _arrowPts.clear();
      });
    } else {
      _finish();
    }
  }

  void _finish() {
    final updatedZones = widget.allZones.map((z) {
      final result = _resolvedArrows[z.zoneId];
      if (result != null) {
        return Zone(
          zoneId:              z.zoneId,
          zoneType:            z.zoneType,
          polygon:             z.polygon,
          legalHeadingDeg:     result.headingDeg,
          headingToleranceDeg: z.headingToleranceDeg,
          vehicleClasses:      z.vehicleClasses,
          needsManualHeading:  false,
        );
      }
      return z;
    }).toList();

    Navigator.pop(context, ZoneTopology(zones: updatedZones));
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (widget.flaggedZones.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _finish());
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Color(0xFF00D4FF))),
      );
    }

    final currentZone = widget.flaggedZones[_currentIndex];
    final zoneNum     = _currentIndex + 1;
    final totalZones  = widget.flaggedZones.length;

    final tapCount = _arrowPts.length;
    final hudLabel = tapCount == 0
        ? 'TAP the TAIL of the direction arrow  (${zoneNum}/$totalZones)'
        : tapCount == 1
            ? 'Now tap the TIP (arrowhead) to finish'
            : 'Direction set — moving on…';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // ── Full-screen drawing canvas ──────────────────────────────────────
          if (_imageReady)
            LayoutBuilder(builder: (ctx, constraints) {
              _updateFit(constraints.biggest);
              return GestureDetector(
                onTapDown: _arrowPts.length < 2 ? _onTap : null,
                child: CustomPaint(
                  size: constraints.biggest,
                  painter: _HeadingPainter(
                    bgImage:      _bgImage,
                    allZones:     widget.allZones,
                    currentZoneId: currentZone.zoneId,
                    resolvedArrows: _resolvedArrows,
                    arrowPts:     List.from(_arrowPts),
                    fitScale:     _fitScale,
                    fitOffset:    _fitOffset,
                    imgW:         widget.frameWidth,
                    imgH:         widget.frameHeight,
                  ),
                ),
              );
            })
          else
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF00D4FF)),
            ),

          // ── Top HUD ─────────────────────────────────────────────────────────
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(children: [
                // Back
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),
                const SizedBox(width: 10),
                // Instruction pill
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.65),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      hudLabel,
                      style: TextStyle(
                        color: tapCount == 1
                            ? const Color(0xFFFFCC00)
                            : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // Undo button
                GestureDetector(
                  onTap: _undoLastPoint,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.withOpacity(0.4)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.undo_rounded, color: Colors.orange, size: 16),
                      SizedBox(width: 4),
                      Text('Undo', style: TextStyle(
                          color: Colors.orange, fontSize: 11,
                          fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Arrow result ────────────────────────────────────────────────────────────────
class _ArrowResult {
  const _ArrowResult({
    required this.tail,
    required this.tip,
    required this.headingDeg,
  });
  final Offset tail;
  final Offset tip;
  final double headingDeg;
}

// ── Painter ─────────────────────────────────────────────────────────────────────
class _HeadingPainter extends CustomPainter {
  _HeadingPainter({
    required this.bgImage,
    required this.allZones,
    required this.currentZoneId,
    required this.resolvedArrows,
    required this.arrowPts,
    required this.fitScale,
    required this.fitOffset,
    required this.imgW,
    required this.imgH,
  });

  final ui.Image? bgImage;
  final List<Zone> allZones;
  final String currentZoneId;
  final Map<String, _ArrowResult> resolvedArrows;
  final List<Offset> arrowPts;
  final double fitScale, imgW, imgH;
  final Offset fitOffset;

  Offset _i2s(Offset p) =>
      Offset(p.dx * fitScale + fitOffset.dx, p.dy * fitScale + fitOffset.dy);

  @override
  void paint(Canvas canvas, Size size) {
    // ── Background image ──────────────────────────────────────────────────────
    if (bgImage != null) {
      final src = Rect.fromLTWH(0, 0, imgW, imgH);
      final dst = Rect.fromLTWH(
          fitOffset.dx, fitOffset.dy, imgW * fitScale, imgH * fitScale);
      canvas.drawImageRect(bgImage!, src, dst, Paint());
    }

    // ── All zone polygons ─────────────────────────────────────────────────────
    for (final zone in allZones) {
      final color = _zoneColor(zone.zoneType);
      final isCurrent = zone.zoneId == currentZoneId;

      _drawZonePolygon(
        canvas,
        zone.polygon,
        color,
        zone.zoneId,
        opacity: isCurrent ? 0.30 : 0.12,
        strokeWidth: isCurrent ? 2.5 : 1.5,
      );

      // Draw confirmed arrow for this zone (if already resolved)
      final arrow = resolvedArrows[zone.zoneId];
      if (arrow != null) {
        _drawArrow(canvas, _i2s(arrow.tail), _i2s(arrow.tip));
      }
    }

    // ── In-progress arrow points for current zone ─────────────────────────────
    const arrowColor = Color(0xFFFFCC00);
    for (int i = 0; i < arrowPts.length; i++) {
      final sp = _i2s(arrowPts[i]);
      canvas.drawCircle(sp, 8,
          Paint()..color = arrowColor..style = PaintingStyle.fill);
      canvas.drawCircle(sp, 8,
          Paint()
            ..color = Colors.black38
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
      _drawLabel(canvas, sp + const Offset(12, -12),
          i == 0 ? 'TAIL' : 'TIP', arrowColor);
    }
    if (arrowPts.length == 2) {
      _drawArrow(canvas, _i2s(arrowPts[0]), _i2s(arrowPts[1]));
    }
  }

  void _drawZonePolygon(
    Canvas canvas,
    List<Offset> pts,
    Color color,
    String label, {
    double opacity = 0.2,
    double strokeWidth = 2.0,
  }) {
    if (pts.length < 3) return;
    final sPts = pts.map(_i2s).toList();
    final path = Path()..moveTo(sPts.first.dx, sPts.first.dy);
    for (final p in sPts.skip(1)) path.lineTo(p.dx, p.dy);
    path.close();

    canvas.drawPath(path, Paint()..color = color.withOpacity(opacity));
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth);

    // Zone label at centroid
    final cx = sPts.map((p) => p.dx).reduce((a, b) => a + b) / sPts.length;
    final cy = sPts.map((p) => p.dy).reduce((a, b) => a + b) / sPts.length;
    _drawLabel(canvas, Offset(cx, cy), label, color);
  }

  void _drawArrow(Canvas canvas, Offset tail, Offset tip) {
    const color = Color(0xFFFFC800);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(tail, tip, paint);

    // Arrowhead
    const headLen   = 14.0;
    const headAngle = 0.45;
    final angle = math.atan2(tip.dy - tail.dy, tip.dx - tail.dx);
    final p1 = Offset(
        tip.dx - headLen * math.cos(angle - headAngle),
        tip.dy - headLen * math.sin(angle - headAngle));
    final p2 = Offset(
        tip.dx - headLen * math.cos(angle + headAngle),
        tip.dy - headLen * math.sin(angle + headAngle));
    final head = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(head, Paint()..color = color);
  }

  void _drawLabel(Canvas canvas, Offset pos, String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          shadows: const [Shadow(color: Colors.black, blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(_HeadingPainter old) => true;
}
