import 'dart:math' as math;
import 'dart:ui' show Offset;

// ---------------------------------------------------------------------------
// IoU
// ---------------------------------------------------------------------------

/// Intersection-over-Union for two axis-aligned bounding boxes.
/// Each box: [x1, y1, x2, y2]
double iou(List<double> a, List<double> b) {
  final x1 = math.max(a[0], b[0]);
  final y1 = math.max(a[1], b[1]);
  final x2 = math.min(a[2], b[2]);
  final y2 = math.min(a[3], b[3]);
  final inter = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
  if (inter == 0) return 0.0;
  final areaA = (a[2] - a[0]) * (a[3] - a[1]);
  final areaB = (b[2] - b[0]) * (b[3] - b[1]);
  final union = areaA + areaB - inter;
  return union > 0 ? inter / union : 0.0;
}

// ---------------------------------------------------------------------------
// Point-in-polygon (ray-casting algorithm)
// ---------------------------------------------------------------------------

/// Returns true if [point] is inside the [polygon] (list of vertices).
bool pointInPolygon(Offset point, List<Offset> polygon) {
  if (polygon.length < 3) return false;
  bool inside = false;
  int j = polygon.length - 1;
  for (int i = 0; i < polygon.length; i++) {
    final xi = polygon[i].dx;
    final yi = polygon[i].dy;
    final xj = polygon[j].dx;
    final yj = polygon[j].dy;

    if (((yi > point.dy) != (yj > point.dy)) &&
        (point.dx < (xj - xi) * (point.dy - yi) / (yj - yi) + xi)) {
      inside = !inside;
    }
    j = i;
  }
  return inside;
}

// ---------------------------------------------------------------------------
// Pixel heading from trajectory
// ---------------------------------------------------------------------------

/// Compute heading (radians, image-space) from the pixel trajectory history.
///
/// Uses the vector from pts[-lookback] to pts[-1].
/// Returns (headingRad, pixelDisplacement) or (null, 0) if not enough points.
(double?, double) pixelHeadingFromPoints(
  List<Offset> pts, {
  int lookback = 15,
}) {
  if (pts.length < 4) return (null, 0.0);
  final startIdx = math.max(0, pts.length - lookback);
  final p0 = pts[startIdx];
  final p1 = pts.last;
  final dx = p1.dx - p0.dx;
  final dy = p1.dy - p0.dy;
  final dist = math.sqrt(dx * dx + dy * dy);
  if (dist < 1e-6) return (null, 0.0);
  return (math.atan2(dy, dx), dist);
}

/// Euclidean displacement over the last [n] points.
double pixelDisplacementLastN(List<Offset> pts, int n) {
  if (pts.length < 2) return 0.0;
  final startIdx = math.max(0, pts.length - n);
  final p0 = pts[startIdx];
  final p1 = pts.last;
  final dx = p1.dx - p0.dx;
  final dy = p1.dy - p0.dy;
  return math.sqrt(dx * dx + dy * dy);
}

// ---------------------------------------------------------------------------
// Angle utilities
// ---------------------------------------------------------------------------

/// Signed angular difference in [−π, π].
double angleDiff(double a, double b) {
  final d = a - b;
  return (d + math.pi) % (2 * math.pi) - math.pi;
}

/// Cosine similarity between two heading vectors.
double directionAlignmentScore(Offset vehicleVec, Offset laneVec) {
  final vn = vehicleVec.distance;
  final ln = laneVec.distance;
  if (vn < 1e-9 || ln < 1e-9) return 0.0;
  return (vehicleVec.dx * laneVec.dx + vehicleVec.dy * laneVec.dy) / (vn * ln);
}

// ---------------------------------------------------------------------------
// Bounding box centre
// ---------------------------------------------------------------------------

/// Centre point of a bounding box [x1, y1, x2, y2].
Offset bboxCentre(List<double> bbox) =>
    Offset((bbox[0] + bbox[2]) / 2, (bbox[1] + bbox[3]) / 2);

/// Bottom-centre of a bounding box (ground contact point).
Offset bboxBottomCentre(List<double> bbox) =>
    Offset((bbox[0] + bbox[2]) / 2, bbox[3]);
