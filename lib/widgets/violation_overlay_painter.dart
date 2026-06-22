import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/material.dart';

import '../fsm/fsm_state.dart';
import '../fsm/track_fsm_state.dart';
import '../fsm/zone_topology.dart';
import '../screens/detection_screen.dart' show DetectionBox;
import '../detectors/helmet_detector.dart' show HelmetStatus;

/// CustomPainter that draws:
///   - Zone overlays (road / footpath / sideland)
///   - Tracked vehicle bounding boxes (coloured by FSM state)
///   - Trajectory lines
///   - Plate detection boxes (cyan)
///   - Helmet detection boxes (green/red)
///   - Violation flash border
class ViolationOverlayPainter extends CustomPainter {
  ViolationOverlayPainter({
    required this.trackStates,
    required this.topology,
    required this.helmetStatusMap,
    required this.recentViolations,
    required this.scaleX,
    required this.scaleY,
    this.showFlashBorder = false,
    this.plateBboxes = const [],
    this.helmetBboxes = const [],
  });

  final Map<int, TrackFsmState> trackStates;
  final ZoneTopology topology;
  final Map<int, HelmetStatus> helmetStatusMap;
  final List<String> recentViolations;
  final double scaleX;
  final double scaleY;
  final bool showFlashBorder;
  final List<DetectionBox> plateBboxes;
  final List<DetectionBox> helmetBboxes;

  // ── Colours per zone type ──────────────────────────────────────────────
  static const _zoneColors = {
    ZoneType.road: Color(0xFF00FF00),
    ZoneType.footpath: Color(0xFFFF3B30),
    ZoneType.sideland: Color(0xFFFFCC00),
    ZoneType.divider: Color(0xFF00D4FF),
  };

  // ── Colours per FSM state ──────────────────────────────────────────────
  static const _fsmColors = {
    FsmState.observing: Color(0xFF34C759),
    FsmState.candidate: Color(0xFFFF9500),
    FsmState.confirmed: Color(0xFFFF3B30),
    FsmState.suppressed: Color(0xFF8E8E93),
    FsmState.parked: Color(0xFF5856D6),
  };

  @override
  void paint(Canvas canvas, Size size) {
    // ── 1. Zone overlays ─────────────────────────────────────────────────
    _drawZones(canvas, size);

    // ── 2. Tracks (vehicle bboxes + trajectories) ─────────────────────────
    _drawTracks(canvas, size);

    // ── 3. Plate boxes ────────────────────────────────────────────────────
    for (final box in plateBboxes) {
      _drawDetectionBox(canvas, box, size);
    }

    // ── 4. Helmet boxes ───────────────────────────────────────────────────
    for (final box in helmetBboxes) {
      _drawDetectionBox(canvas, box, size);
    }

    // ── 5. Flash border ───────────────────────────────────────────────────
    if (showFlashBorder) {
      _drawFlashBorder(canvas, size);
    }
  }

  void _drawZones(Canvas canvas, Size size) {
    for (final zone in topology.zones) {
      if (zone.polygon.isEmpty) continue;
      final color = _zoneColors[zone.zoneType] ?? const Color(0xFF888888);
      final scaledPts = zone.polygon
          .map((p) => Offset(p.dx * scaleX, p.dy * scaleY))
          .toList();

      final path = Path()..moveTo(scaledPts.first.dx, scaledPts.first.dy);
      for (final pt in scaledPts.skip(1)) {
        path.lineTo(pt.dx, pt.dy);
      }
      path.close();

      // Translucent fill
      canvas.drawPath(path, Paint()..color = color.withOpacity(0.13));
      // Border
      canvas.drawPath(
          path,
          Paint()
            ..color = color.withOpacity(0.8)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);

      // Zone label
      final cx = scaledPts.map((p) => p.dx).reduce((a, b) => a + b) / scaledPts.length;
      final cy = scaledPts.map((p) => p.dy).reduce((a, b) => a + b) / scaledPts.length;
      _drawText(canvas, '[${zone.zoneType.name}]', Offset(cx, cy),
          fontSize: 10, color: color);
    }
  }

  void _drawTracks(Canvas canvas, Size size) {
    for (final entry in trackStates.entries) {
      final tid = entry.key;
      final state = entry.value;
      final bbox = state.bbox;
      if (bbox.length < 4) continue;

      final x1 = bbox[0] * scaleX;
      final y1 = bbox[1] * scaleY;
      final x2 = bbox[2] * scaleX;
      final y2 = bbox[3] * scaleY;

      final color = _fsmColors[state.fsm] ?? const Color(0xFF34C759);

      // Bounding box
      final rect = Rect.fromLTRB(x1, y1, x2, y2);
      canvas.drawRect(
          rect,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0);

      // Track label
      final label = '#$tid ${state.vehicleClass} [${state.fsm.name}]';
      _drawText(canvas, label, Offset(x1, math.max(0, y1 - 8)),
          fontSize: 10, color: color, bgOpacity: 0.5);

      // Helmet badge (motorcycles / two-wheelers)
      if (state.vehicleClass == 'motorcycle' || state.vehicleClass == 'two-wheeler') {
        final status = helmetStatusMap[tid] ?? HelmetStatus.unknown;
        Color badgeColor;
        String badgeText;
        switch (status) {
          case HelmetStatus.noHelmet:
            badgeColor = const Color(0xFFFF3B30); // Red
            badgeText = 'NO HELMET ✕';
            break;
          case HelmetStatus.hasHelmet:
            badgeColor = const Color(0xFF34C759); // Green
            badgeText = 'HELMET ✓';
            break;
          case HelmetStatus.unknown:
          default:
            badgeColor = const Color(0xFFFF9500); // Orange
            badgeText = 'HELMET ?';
            break;
        }

        _drawText(canvas, badgeText, Offset(x1, y2 + 14),
            fontSize: 10, color: badgeColor, bgOpacity: 0.6);
      }

      // Trajectory
      final pts = state.trajectoryList;
      if (pts.length >= 2) {
        final tPaint = Paint()
          ..color = const Color(0xFFFFD60A).withOpacity(0.7)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke;
        final tPath = Path();
        tPath.moveTo(pts.first.dx * scaleX, pts.first.dy * scaleY);
        for (final p in pts.skip(1)) {
          tPath.lineTo(p.dx * scaleX, p.dy * scaleY);
        }
        canvas.drawPath(tPath, tPaint);
      }
    }
  }

  void _drawFlashBorder(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFF3B30).withOpacity(0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    canvas.drawRect(
        Rect.fromLTWH(3, 3, size.width - 6, size.height - 6), paint);
  }

  void _drawDetectionBox(Canvas canvas, DetectionBox box, Size size) {
    // The YOLOResult.boundingBox from secondary models is in absolute px
    // relative to the image. Scale to screen.
    final rect = Rect.fromLTRB(
      box.rect.left  * scaleX,
      box.rect.top   * scaleY,
      box.rect.right * scaleX,
      box.rect.bottom* scaleY,
    );
    // Box outline (dashed appearance via two rects)
    canvas.drawRect(rect, Paint()
      ..color = box.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0);
    // Corner accents
    const cLen = 10.0;
    final cp = Paint()..color = box.color..strokeWidth = 3..strokeCap = StrokeCap.round;
    // TL
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(cLen, 0), cp);
    canvas.drawLine(rect.topLeft, rect.topLeft + const Offset(0, cLen), cp);
    // TR
    canvas.drawLine(rect.topRight, rect.topRight - const Offset(cLen, 0), cp);
    canvas.drawLine(rect.topRight, rect.topRight + const Offset(0, cLen), cp);
    // BL
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft + const Offset(cLen, 0), cp);
    canvas.drawLine(rect.bottomLeft, rect.bottomLeft - const Offset(0, cLen), cp);
    // BR
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(cLen, 0), cp);
    canvas.drawLine(rect.bottomRight, rect.bottomRight - const Offset(0, cLen), cp);
    // Label
    final labelText = '${box.label} ${(box.confidence * 100).toStringAsFixed(0)}%';
    _drawText(canvas, labelText,
        Offset(rect.left, math.max(0, rect.top - 16)),
        fontSize: 10, color: box.color, bgOpacity: 0.55);
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset position, {
    double fontSize = 12,
    Color color = Colors.white,
    double bgOpacity = 0.0,
  }) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              color: color,
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              shadows: const [
                Shadow(color: Colors.black, blurRadius: 3)
              ])),
      textDirection: TextDirection.ltr,
    )..layout();

    if (bgOpacity > 0) {
      canvas.drawRect(
          Rect.fromLTWH(position.dx - 2, position.dy - 2,
              tp.width + 4, tp.height + 2),
          Paint()..color = Colors.black.withOpacity(bgOpacity));
    }
    tp.paint(canvas, position);
  }

  @override
  bool shouldRepaint(ViolationOverlayPainter old) => true;
}
