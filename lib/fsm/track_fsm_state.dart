import 'dart:collection';
import 'dart:ui' show Offset;

import 'fsm_state.dart';

/// Per-track mutable state carried across frames.
class TrackFsmState {
  TrackFsmState({
    required this.trackId,
    required this.vehicleClass,
    required this.frameFirstSeen,
  });

  final int trackId;
  final String vehicleClass;
  final int frameFirstSeen;

  // ── FSM ──────────────────────────────────────────────────────────
  FsmState fsm = FsmState.observing;
  int wrongDirectionFrames = 0;
  int stoppedFrames = 0;
  int suppressFramesRemaining = 0;
  int candidateFrames = 0;

  // ── Trajectory ───────────────────────────────────────────────────
  /// Rolling pixel trajectory (bottom-centre of bbox), max 60 points.
  final Queue<Offset> pixelPts = Queue();
  static const int trajectoryMaxLen = 60;

  void addPoint(Offset pt) {
    pixelPts.addLast(pt);
    if (pixelPts.length > trajectoryMaxLen) pixelPts.removeFirst();
  }

  List<Offset> get trajectoryList => pixelPts.toList();

  // ── Current state ─────────────────────────────────────────────────
  double? headingRad;
  double pixelDisplacement = 0.0;
  List<String> currentZones = [];
  List<double> bbox = [0, 0, 0, 0];
  int frameLastSeen = 0;

  // ── Footpath tracking ─────────────────────────────────────────────
  int footpathFrameCounter = 0;
  bool currentlyInFootpath = false;

  // ── Sideland tracking ─────────────────────────────────────────────
  int sidelandFrameCounter = 0;
  bool currentlyInSideland = false;

  // ── Detection confidence history ──────────────────────────────────
  final Queue<double> detectionConfs = Queue();
  double get avgDetConf {
    if (detectionConfs.isEmpty) return 0.5;
    return detectionConfs.fold(0.0, (a, b) => a + b) / detectionConfs.length;
  }

  void addConf(double c) {
    detectionConfs.addLast(c);
    if (detectionConfs.length > 30) detectionConfs.removeFirst();
  }

  // ── Confirmed violation ───────────────────────────────────────────
  ViolationEvent? confirmedViolation;

  int get trackAge => frameLastSeen - frameFirstSeen + 1;
}
