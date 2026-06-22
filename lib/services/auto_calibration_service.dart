import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show Offset;
import 'package:flutter/foundation.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../fsm/fsm_state.dart';
import '../fsm/geometry.dart';
import '../fsm/zone_topology.dart';

class _TrackMovement {
  _TrackMovement(this.firstPoint) : latestPoint = firstPoint;
  Offset firstPoint;
  Offset latestPoint;
  double? latestHeadingRad;

  double get displacement => (latestPoint - firstPoint).distance;

  double get headingDeg {
    if (latestHeadingRad != null) {
      double deg = latestHeadingRad! * 180 / math.pi;
      return (deg + 360) % 360;
    }
    final dx = latestPoint.dx - firstPoint.dx;
    final dy = latestPoint.dy - firstPoint.dy;
    double rad = math.atan2(dy, dx);
    double deg = rad * 180 / math.pi;
    return (deg + 360) % 360;
  }
}

class AutoCalibrationService {
  AutoCalibrationService();

  int? _maskW;
  int? _maskH;
  int _totalProcessedFrames = 0;

  // Heatmaps for each ZoneType
  final Map<ZoneType, List<List<int>>> _heatmaps = {};

  // Tracked vehicle movements
  final Map<int, _TrackMovement> _trackMovements = {};

  // Flag to check if we have received at least one valid road mask
  bool get hasCalibratedRoad => _maskW != null;

  void reset() {
    _maskW = null;
    _maskH = null;
    _totalProcessedFrames = 0;
    _heatmaps.clear();
    _trackMovements.clear();
  }

  void _ensureHeatmapInit(int h, int w) {
    if (_maskW != null) return;
    _maskW = w;
    _maskH = h;
    for (final type in ZoneType.values) {
      _heatmaps[type] = List.generate(h, (_) => List.filled(w, 0));
    }
    debugPrint('[AutoCalibration] Heatmaps initialized to ${w}x$h');
  }

  /// Feed segmentation results from a calibration frame.
  void addSegmentationFrame(List<YOLOResult> results) {
    if (results.isEmpty) return;

    // Find the first result with a valid mask to get coordinates size
    YOLOResult? firstMaskResult;
    for (final r in results) {
      if (r.mask != null && r.mask!.isNotEmpty && r.mask![0].isNotEmpty) {
        firstMaskResult = r;
        break;
      }
    }
    if (firstMaskResult == null) return;

    final h = firstMaskResult.mask!.length;
    final w = firstMaskResult.mask![0].length;
    _ensureHeatmapInit(h, w);

    _totalProcessedFrames++;

    // Local binary grid per type to avoid multiple counts in same frame
    final frameGrids = {
      for (final type in ZoneType.values)
        type: List.generate(h, (_) => List.filled(w, false))
    };

    for (final r in results) {
      if (r.mask == null) continue;

      ZoneType? type;
      final cleanName = r.className.toLowerCase().replaceAll('_', '').replaceAll('-', '').trim();
      // NOTE: native classIndex is always 0 (known bug) — derive type from className only.
      if (cleanName == 'divider') {
        type = ZoneType.divider;
      } else if (cleanName == 'footpath') {
        type = ZoneType.footpath;
      } else if (cleanName == 'road') {
        type = ZoneType.road;
      } else if (cleanName == 'sideland') {
        type = ZoneType.sideland;
      } else {
        // True fallback: classIndex already patched in RoadDetector
        switch (r.classIndex) {
          case 0: type = ZoneType.divider;
          case 1: type = ZoneType.footpath;
          case 2: type = ZoneType.road;
          case 3: type = ZoneType.sideland;
        }
      }


      if (type == null) continue;
      final grid = frameGrids[type]!;
      final mask = r.mask!;
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          // raw logit value > 0 means sigmoid probability > 0.5
          if (mask[y][x] > 0.0) {
            grid[y][x] = true;
          }
        }
      }
    }

    // Accumulate in global heatmap
    for (final type in ZoneType.values) {
      final fGrid = frameGrids[type]!;
      final hGrid = _heatmaps[type]!;
      int pixelCount = 0;
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          if (fGrid[y][x]) {
            hGrid[y][x]++;
            pixelCount++;
          }
        }
      }
      if (pixelCount > 0) {
        debugPrint('[AutoCalibration] Frame $_totalProcessedFrames: ${type.name} → $pixelCount mask pixels (mask ${w}x$h)');
      }
    }
  }

  /// Add a vehicle track point to monitor its direction during calibration.
  void addVehicleTrackPoint(int trackId, Offset bottomCentroid) {
    final movement = _trackMovements[trackId];
    if (movement == null) {
      _trackMovements[trackId] = _TrackMovement(bottomCentroid);
    } else {
      movement.latestPoint = bottomCentroid;
    }
  }

  /// Add a vehicle track heading to monitor its trajectory direction.
  void addVehicleHeading(int trackId, double headingRad) {
    final movement = _trackMovements[trackId];
    if (movement != null) {
      movement.latestHeadingRad = headingRad;
    } else {
      _trackMovements[trackId] = _TrackMovement(Offset.zero)..latestHeadingRad = headingRad;
    }
  }

  /// Run contour tracing, polygon simplification to build the initial [ZoneTopology]
  /// with placeholder headings (Phase 1).
  ZoneTopology finalizeCalibration({
    required double frameWidth,
    required double frameHeight,
    double ratioThreshold = 0.35,
    double rdpEpsilon = 12.0,
    int minPixelArea = 40,
  }) {
    if (_totalProcessedFrames == 0 || _maskW == null) {
      debugPrint('[AutoCalibration] No frames processed, returning fallback.');
      return ZoneTopology.fallback(frameWidth, frameHeight);
    }

    final List<Zone> finalizedZones = [];
    int zoneCounter = 1;

    for (final type in ZoneType.values) {
      // 1. Threshold heatmap to binary grid
      final grid = _getThresholdedGrid(type, ratioThreshold);

      // 2. Find contours
      final contours = _findContours(grid, minPixelArea);

      // 3. Process each contour
      for (final rawContour in contours) {
        // Scale contour to actual camera frame resolution
        final scaledContour = rawContour.map((pt) {
          final sx = (pt.dx / _maskW!) * frameWidth;
          final sy = (pt.dy / _maskH!) * frameHeight;
          return Offset(sx, sy);
        }).toList();

        // Simplify using Ramer-Douglas-Peucker (RDP)
        final simplified = _ramerDouglasPeucker(scaledContour, rdpEpsilon);
        if (simplified.length < 3) continue;

        // Create the Zone
        final zoneId = '${type.name}_$zoneCounter';
        zoneCounter++;

        finalizedZones.add(Zone(
          zoneId: zoneId,
          zoneType: type,
          polygon: simplified,
          legalHeadingDeg: 0.0,
          headingToleranceDeg: 40.0,
          vehicleClasses: const ['all'],
          needsManualHeading: false,
        ));
      }
    }

    if (finalizedZones.isEmpty) {
      debugPrint('[AutoCalibration] No zones detected, returning fallback.');
      return ZoneTopology.fallback(frameWidth, frameHeight);
    }

    debugPrint('[AutoCalibration] Saved ${finalizedZones.length} auto-detected zones.');
    return ZoneTopology(zones: finalizedZones);
  }

  /// Finalize calibration from a single segmentation frame's results.
  ZoneTopology finalizeFromSingleFrame({
    required List<YOLOResult> results,
    required double frameWidth,
    required double frameHeight,
    double rdpEpsilon = 12.0,
    int minPixelArea = 40,
  }) {
    reset();
    addSegmentationFrame(results);
    return finalizeCalibration(
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      ratioThreshold: 0.1,
      rdpEpsilon: rdpEpsilon,
      minPixelArea: minPixelArea,
    );
  }

  /// Assign headings to road zones based on tracked vehicles (Phase 2).
  /// Flags zones with no observed vehicles with needsManualHeading = true.
  ZoneTopology assignHeadingsToZones(List<Zone> phase1Zones) {
    final List<Zone> finalizedZones = [];

    for (final zone in phase1Zones) {
      if (zone.zoneType != ZoneType.road) {
        // Non-road zones don't need headings, just copy them as is
        finalizedZones.add(Zone(
          zoneId: zone.zoneId,
          zoneType: zone.zoneType,
          polygon: zone.polygon,
          legalHeadingDeg: 0.0,
          headingToleranceDeg: zone.headingToleranceDeg,
          vehicleClasses: zone.vehicleClasses,
          needsManualHeading: false,
        ));
        continue;
      }

      final validHeadings = <double>[];

      for (final m in _trackMovements.values) {
        if (m.displacement < 45.0) continue;

        // Find the midpoint of the track
        final midPoint = Offset(
          (m.firstPoint.dx + m.latestPoint.dx) / 2,
          (m.firstPoint.dy + m.latestPoint.dy) / 2,
        );

        // Check if this vehicle is inside the road zone
        if (pointInPolygon(midPoint, zone.polygon)) {
          validHeadings.add(m.headingDeg);
        }
      }

      if (validHeadings.isEmpty) {
        // No vehicles were observed inside the polygon, leave legalHeadingDeg = 0.0
        // and flag that zone as needsManualHeading = true
        debugPrint('[AutoCalibration] No vehicle tracks observed in road zone ${zone.zoneId}. Needs manual heading.');
        finalizedZones.add(Zone(
          zoneId: zone.zoneId,
          zoneType: zone.zoneType,
          polygon: zone.polygon,
          legalHeadingDeg: 0.0,
          headingToleranceDeg: zone.headingToleranceDeg,
          vehicleClasses: zone.vehicleClasses,
          needsManualHeading: true,
        ));
      } else {
        final avgHeading = _circularMean(validHeadings);
        debugPrint(
          '[AutoCalibration] Zone ${zone.zoneId}: Computed legal heading from ${validHeadings.length} vehicles: ${avgHeading.toStringAsFixed(1)}°',
        );
        finalizedZones.add(Zone(
          zoneId: zone.zoneId,
          zoneType: zone.zoneType,
          polygon: zone.polygon,
          legalHeadingDeg: avgHeading,
          headingToleranceDeg: zone.headingToleranceDeg,
          vehicleClasses: zone.vehicleClasses,
          needsManualHeading: false,
        ));
      }
    }

    return ZoneTopology(zones: finalizedZones);
  }

  /// Returns a live preview representation of polygons detected so far,
  /// used for on-screen real-time visualization during calibration.
  ZoneTopology getLiveTopologyPreview(double frameW, double frameH) {
    if (_maskW == null) return ZoneTopology(zones: []);
    final List<Zone> tempZones = [];
    int zoneCounter = 1;

    // Use a lower threshold (e.g. 0.20) for more responsive live rendering
    for (final type in ZoneType.values) {
      final grid = _getThresholdedGrid(type, 0.20);
      final contours = _findContours(grid, 30);
      for (final rawContour in contours) {
        final scaled = rawContour.map((pt) {
          return Offset((pt.dx / _maskW!) * frameW, (pt.dy / _maskH!) * frameH);
        }).toList();
        final simplified = _ramerDouglasPeucker(scaled, 15.0);
        if (simplified.length < 3) continue;

        tempZones.add(Zone(
          zoneId: 'live_${type.name}_$zoneCounter',
          zoneType: type,
          polygon: simplified,
        ));
        zoneCounter++;
      }
    }
    return ZoneTopology(zones: tempZones);
  }

  // ── Helper Algorithms ──────────────────────────────────────────────────────

  List<List<bool>> _getThresholdedGrid(ZoneType type, double ratioThreshold) {
    final h = _maskH!;
    final w = _maskW!;
    final hm = _heatmaps[type]!;
    final grid = List.generate(h, (_) => List.filled(w, false));

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final ratio = hm[y][x] / _totalProcessedFrames;
        if (ratio >= ratioThreshold) {
          grid[y][x] = true;
        }
      }
    }
    return grid;
  }

  List<List<Offset>> _findContours(List<List<bool>> grid, int minArea) {
    final h = grid.length;
    final w = grid[0].length;
    final visited = <int>{};
    final List<List<Offset>> contours = [];

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final idx = y * w + x;
        if (grid[y][x] && !visited.contains(idx)) {
          // We found a new component. First flood fill to get total area and mark visited
          final componentPixels = _floodFill(x, y, grid, visited);
          if (componentPixels.length >= minArea) {
            // Trace the outer boundary of this component
            final contour = _traceContour(x, y, grid);
            if (contour.length >= 4) {
              contours.add(contour);
            }
          }
        }
      }
    }
    return contours;
  }

  /// Flood fill to mark all component pixels as visited and return them.
  List<math.Point<int>> _floodFill(
    int startX,
    int startY,
    List<List<bool>> grid,
    Set<int> visitedGlobal,
  ) {
    final h = grid.length;
    final w = grid[0].length;
    final List<math.Point<int>> component = [];
    final queue = Queue<math.Point<int>>();

    final startPoint = math.Point(startX, startY);
    queue.add(startPoint);
    visitedGlobal.add(startY * w + startX);

    while (queue.isNotEmpty) {
      final p = queue.removeFirst();
      component.add(p);

      final neighbors = [
        math.Point(p.x + 1, p.y),
        math.Point(p.x - 1, p.y),
        math.Point(p.x, p.y + 1),
        math.Point(p.x, p.y - 1),
      ];

      for (final n in neighbors) {
        if (n.x >= 0 && n.x < w && n.y >= 0 && n.y < h) {
          if (grid[n.y][n.x]) {
            final idx = n.y * w + n.x;
            if (!visitedGlobal.contains(idx)) {
              visitedGlobal.add(idx);
              queue.add(n);
            }
          }
        }
      }
    }
    return component;
  }

  /// Moore-Neighbor boundary tracing algorithm.
  List<Offset> _traceContour(int startX, int startY, List<List<bool>> grid) {
    final h = grid.length;
    final w = grid[0].length;
    final contour = <Offset>[];

    int cx = startX;
    int cy = startY;

    // Clockwise directions (0: N, 1: NE, 2: E, 3: SE, 4: S, 5: SW, 6: W, 7: NW)
    final dirs = const [
      Offset(0, -1),
      Offset(1, -1),
      Offset(1, 0),
      Offset(1, 1),
      Offset(0, 1),
      Offset(-1, 1),
      Offset(-1, 0),
      Offset(-1, -1),
    ];

    int dir = 6; // start looking west since we scanned left-to-right
    int limit = 10000;

    do {
      contour.add(Offset(cx.toDouble(), cy.toDouble()));

      bool foundNext = false;
      int searchStart = (dir + 5) % 8;
      for (int i = 0; i < 8; i++) {
        int checkDir = (searchStart + i) % 8;
        int nx = cx + dirs[checkDir].dx.toInt();
        int ny = cy + dirs[checkDir].dy.toInt();

        if (ny >= 0 && ny < h && nx >= 0 && nx < w) {
          if (grid[ny][nx]) {
            cx = nx;
            cy = ny;
            dir = checkDir;
            foundNext = true;
            break;
          }
        }
      }

      if (!foundNext) break;
      limit--;
    } while ((cx != startX || cy != startY) && limit > 0);

    return contour;
  }

  /// Ramer-Douglas-Peucker polygon simplification algorithm.
  List<Offset> _ramerDouglasPeucker(List<Offset> points, double epsilon) {
    if (points.length < 3) return points;

    double maxDistance = 0.0;
    int index = 0;
    final end = points.length - 1;

    for (int i = 1; i < end; i++) {
      final distance = _perpendicularDistance(points[i], points[0], points[end]);
      if (distance > maxDistance) {
        index = i;
        maxDistance = distance;
      }
    }

    if (maxDistance > epsilon) {
      final results1 = _ramerDouglasPeucker(points.sublist(0, index + 1), epsilon);
      final results2 = _ramerDouglasPeucker(points.sublist(index), epsilon);
      return [...results1.sublist(0, results1.length - 1), ...results2];
    } else {
      return [points[0], points[end]];
    }
  }

  double _perpendicularDistance(Offset p, Offset p1, Offset p2) {
    final double dx = p2.dx - p1.dx;
    final double dy = p2.dy - p1.dy;
    if (dx == 0.0 && dy == 0.0) {
      return (p - p1).distance;
    }
    final double t =
        ((p.dx - p1.dx) * dx + (p.dy - p1.dy) * dy) / (dx * dx + dy * dy);
    final double clampedT = t.clamp(0.0, 1.0);
    final Offset projection = p1 + Offset(dx * clampedT, dy * clampedT);
    return (p - projection).distance;
  }


  double _circularMean(List<double> anglesDeg) {
    double sumSin = 0.0;
    double sumCos = 0.0;
    for (final angle in anglesDeg) {
      final rad = angle * math.pi / 180;
      sumSin += math.sin(rad);
      sumCos += math.cos(rad);
    }
    final avgRad = math.atan2(sumSin, sumCos);
    final avgDeg = avgRad * 180 / math.pi;
    return (avgDeg + 360) % 360;
  }
}
