/// FSM states for the per-track violation state machine.
enum FsmState {
  observing,
  candidate,
  confirmed,
  suppressed,
  parked,
}

/// Zone types.
enum ZoneType { road, footpath, sideland, divider }

/// A violation event emitted when an FSM confirms a violation.
class ViolationEvent {
  ViolationEvent({
    required this.trackId,
    required this.vehicleClass,
    required this.violationType,
    required this.zoneId,
    required this.frameNumber,
    required this.timestampS,
    required this.confidence,
    required this.headingDeg,
    this.legalHeadingDeg,
    this.candidateFrames,
    required this.bboxPx,
    required this.isCongested,
    required this.weather,
  });

  final int trackId;
  final String vehicleClass;
  final String violationType;
  final String zoneId;
  final int frameNumber;
  final double timestampS;
  final double confidence;
  final double? headingDeg;
  final double? legalHeadingDeg;
  final int? candidateFrames;
  final List<double> bboxPx;
  final bool isCongested;
  final String weather;

  /// Bbox as [x1, y1, x2, y2] (alias for bboxPx).
  List<double> get bbox => bboxPx;

  /// Formatted timestamp string "HH:MM:SS.d"
  String get timestampStr {
    final h = (timestampS ~/ 3600);
    final m = ((timestampS % 3600) ~/ 60);
    final s = timestampS % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(1).padLeft(4, '0')}';
  }

  @override
  String toString() =>
      'ViolationEvent[$violationType track=$trackId frame=$frameNumber]';
}

// ── Violation type constants ──────────────────────────────────────────────

const kViolationWrongSide = 'wrong_side';
const kViolationFootpath = 'footpath_driving';
const kViolationNoHelmet = 'no_helmet';
const kViolationDividerCrossing = 'divider_crossing';
