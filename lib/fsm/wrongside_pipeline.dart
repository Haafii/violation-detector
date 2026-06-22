import 'dart:ui' show Offset;

import '../tracker/byte_tracker.dart';
import 'fsm_state.dart';
import 'geometry.dart';
import 'track_fsm_state.dart';
import 'violation_fsm.dart';
import 'zone_topology.dart';

/// Per-frame coordinator: feeds YOLO detections → ByteTracker → FSM
/// and emits [ViolationEvent]s.
///
/// Mirrors the Python WrongSidePipeline.
class WrongSidePipeline {
  WrongSidePipeline({
    required this.topology,
    this.fps = 25.0,
    double trackThresh = 0.4,
    double highThresh = 0.5,
  }) : _tracker = ByteTracker(
          trackThresh: trackThresh,
          highThresh: highThresh,
          matchThresh: 0.8,
          trackBuffer: 30,
          frameRate: fps.toInt(),
        );

  final ZoneTopology topology;
  final double fps;
  final ByteTracker _tracker;

  /// Public track states keyed by track_id.
  final Map<int, TrackFsmState> trackStates = {};

  // Per-zone congestion flags.
  final Map<String, bool> _zoneCongestion = {};

  static const int _maxTrackStates = 200;

  // ── Main entry point ─────────────────────────────────────────────────────

  /// Process one frame of YOLO detections.
  /// Returns list of new ViolationEvents fired this frame.
  List<ViolationEvent> updateDetections(
    List<Detection> detections,
    int frameNum,
    double ts, {
    double frameWidth = 720,
    double frameHeight = 1280,
  }) {
    // ── 1. Track via ByteTracker ──────────────────────────────────────────
    final tracked = _tracker.update(detections);

    // ── 2. Congestion check every 15 frames ───────────────────────────────
    if (frameNum % 15 == 0) {
      _updateCongestion(tracked);
    }

    final events = <ViolationEvent>[];
    final activeIds = <int>{};

    for (final track in tracked) {
      final tid = track.trackId;
      activeIds.add(tid);

      final vclass = track.className.isNotEmpty ? track.className.toLowerCase() : _vehicleClassName(track.classId);

      // Init track state if new
      if (!trackStates.containsKey(tid)) {
        trackStates[tid] = TrackFsmState(
          trackId: tid,
          vehicleClass: vclass,
          frameFirstSeen: frameNum,
        );
      }

      final state = trackStates[tid]!;
      state.frameLastSeen = frameNum;
      state.bbox = track.bbox;
      state.addConf(track.score);

      // ── Pixel centroid (bottom-centre = ground contact) ────────────────
      final cx = (track.bbox[0] + track.bbox[2]) / 2;
      final cy = track.bbox[3];
      final pt = Offset(cx, cy);
      state.addPoint(pt);

      // ── Heading & displacement ─────────────────────────────────────────
      final pts = state.trajectoryList;
      final (hdg, disp) = pixelHeadingFromPoints(pts, lookback: 15);
      state.headingRad = hdg;
      state.pixelDisplacement = disp;
      final recentDisp = pixelDisplacementLastN(pts, 5);

      // ── Zone lookup ───────────────────────────────────────────────────
      final zonesHere = topology.getZonesForPoint(pt);
      state.currentZones = zonesHere.map((z) => z.zoneId).toList();

      final inSideland = topology.isInSidelandZone(pt);

      // ── Run FSM for each road zone ─────────────────────────────────────
      for (final zone in zonesHere) {
        final congested = _zoneCongestion[zone.zoneId] ?? false;
        final event = ViolationFSM.update(
          state: state,
          zone: zone,
          headingRad: hdg,
          pixelDisplacement: recentDisp,
          frameNum: frameNum,
          isCongested: congested,
          isInUturnZone: false, // simplified — no U-turn zones in mobile MVP
          isInSidelandZone: inSideland,
          weather: 'day',
        );
        if (event != null) {
          events.add(event);
        }
      }

      // ── Footpath detection ────────────────────────────────────────────
      final inFootpath = topology.isInFootpathZone(pt);
      if (inFootpath) {
        state.footpathFrameCounter++;
        if (state.footpathFrameCounter >= kFootpathConfirmFrames &&
            !state.currentlyInFootpath) {
          state.currentlyInFootpath = true;
          events.add(_buildSimpleEvent(
            state,
            kViolationFootpath,
            state.currentZones.isNotEmpty ? state.currentZones.first : 'footpath',
            frameNum,
            ts,
          ));
        }
      } else {
        state.footpathFrameCounter = 0;
        state.currentlyInFootpath = false;
      }
    }

    // ── Remove lost tracks ────────────────────────────────────────────────
    final lostIds = trackStates.keys.where((id) => !activeIds.contains(id)).toList();
    for (final id in lostIds) {
      trackStates.remove(id);
    }
    // Hard cap
    if (trackStates.length > _maxTrackStates) {
      final oldest = trackStates.entries.toList()
        ..sort((a, b) => a.value.frameLastSeen.compareTo(b.value.frameLastSeen));
      for (int i = 0; i < trackStates.length - _maxTrackStates; i++) {
        trackStates.remove(oldest[i].key);
      }
    }

    return events;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  static const List<String> _vehicleClasses = [
    'car', 'motorcycle', 'bus', 'truck', 'autorickshaw'
  ];

  static String _vehicleClassName(int classId) {
    if (classId < 0 || classId >= _vehicleClasses.length) return 'car';
    return _vehicleClasses[classId];
  }

  void _updateCongestion(List<dynamic> tracked) {
    // Simple heuristic: if >70% of tracked vehicles are near-stationary → congested
    for (final zone in topology.roadZones) {
      final zoneDisps = <double>[];
      for (final entry in trackStates.entries) {
        if (entry.value.currentZones.contains(zone.zoneId)) {
          zoneDisps.add(entry.value.pixelDisplacement);
        }
      }
      if (zoneDisps.length >= 4) {
        final slow = zoneDisps.where((d) => d < kStoppedPixelMovement * 3).length;
        _zoneCongestion[zone.zoneId] = slow / zoneDisps.length >= 0.7;
      } else {
        _zoneCongestion[zone.zoneId] = false;
      }
    }
  }

  ViolationEvent _buildSimpleEvent(
    TrackFsmState state,
    String violationType,
    String zoneId,
    int frameNum,
    double ts,
  ) {
    return ViolationEvent(
      trackId: state.trackId,
      vehicleClass: state.vehicleClass,
      violationType: violationType,
      zoneId: zoneId,
      frameNumber: frameNum,
      timestampS: ts,
      confidence: state.avgDetConf,
      headingDeg: state.headingRad != null
          ? state.headingRad! * 180 / 3.14159265
          : null,
      bboxPx: List<double>.from(state.bbox),
      isCongested: false,
      weather: 'day',
    );
  }
}
