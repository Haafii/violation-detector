import 'dart:math' as math;

import 'fsm_state.dart';
import 'geometry.dart';
import 'track_fsm_state.dart';
import 'zone_topology.dart';

// ── Thresholds (mirrors config.yaml) ─────────────────────────────────────────

const int kMinWrongFramesDefault = 8;
const int kMinWrongFramesCongested = 12;
const int kCandidateConfirmFrames = 5;
const int kStoppedFramesThreshold = 45;
const double kStoppedPixelMovement = 8.0;
const double kHeadingToleranceDeg = 30.0;
const double kMotorcycleToleranceDeg = 40.0;
const int kSuppressCooldownFrames = 30;

const int kFootpathConfirmFrames = 8;
const int kSidelandConfirmFrames = 8;

/// Dart port of the Python ViolationFSM.
///
/// Call [update] once per frame per (track, zone) pair.
/// Returns a [ViolationEvent] if a wrong-side violation is confirmed, else null.
class ViolationFSM {
  static ViolationEvent? update({
    required TrackFsmState state,
    required Zone zone,
    required double? headingRad,
    required double pixelDisplacement,
    required int frameNum,
    required bool isCongested,
    required bool isInUturnZone,
    required bool isInSidelandZone,
    required String weather,
  }) {
    // Only handle road zones for wrong-side FSM
    if (zone.zoneType != ZoneType.road) return null;

    final vclass = state.vehicleClass;

    // ── Resolve thresholds ──────────────────────────────────────────────
    int minWrongFrames = isCongested
        ? kMinWrongFramesCongested
        : kMinWrongFramesDefault;

    int candidateConfirm = kCandidateConfirmFrames;
    if (vclass == 'motorcycle' || vclass == 'autorickshaw') {
      candidateConfirm += 2;
    }
    if (isCongested) candidateConfirm += 3;

    double tolRad = math.pi / 180 *
        ((vclass == 'motorcycle' || vclass == 'autorickshaw')
            ? kMotorcycleToleranceDeg
            : zone.headingToleranceDeg);

    final legalHeadingRad = zone.legalHeadingDeg * math.pi / 180;

    // ── Compute is_wrong_way ────────────────────────────────────────────
    bool isWrongWay = false;
    if (headingRad != null) {
      final diff = angleDiff(headingRad, legalHeadingRad).abs();
      isWrongWay = diff > (math.pi - tolRad);
    }

    final fsm = state.fsm;

    // ── PARKED ─────────────────────────────────────────────────────────
    if (fsm == FsmState.parked) {
      if (pixelDisplacement > kStoppedPixelMovement * 2) {
        state.fsm = FsmState.observing;
        state.wrongDirectionFrames = 0;
        state.stoppedFrames = 0;
      }
      return null;
    }

    // ── SUPPRESSED ─────────────────────────────────────────────────────
    if (fsm == FsmState.suppressed) {
      state.suppressFramesRemaining--;
      if (state.suppressFramesRemaining <= 0) {
        state.fsm = FsmState.observing;
        state.wrongDirectionFrames = 0;
        state.candidateFrames = 0;
      }
      return null;
    }

    // ── CONFIRMED ─────────────────────────────────────────────────────
    if (fsm == FsmState.confirmed) {
      if (!isWrongWay) {
        state.fsm = FsmState.observing;
        state.wrongDirectionFrames = 0;
        state.candidateFrames = 0;
        state.stoppedFrames = 0;
      }
      return null; // event already fired
    }

    // ── CANDIDATE ─────────────────────────────────────────────────────
    if (fsm == FsmState.candidate) {
      if (isInUturnZone || isInSidelandZone || !isWrongWay) {
        state.candidateFrames = 0;
        state.fsm = FsmState.suppressed;
        state.suppressFramesRemaining = kSuppressCooldownFrames;
        return null;
      }
      state.candidateFrames++;
      if (state.candidateFrames >= candidateConfirm) {
        state.fsm = FsmState.confirmed;
        final event = _buildViolationEvent(
          state: state,
          zone: zone,
          violationType: kViolationWrongSide,
          frameNum: frameNum,
          headingRad: headingRad,
          isCongested: isCongested,
          weather: weather,
        );
        state.confirmedViolation = event;
        return event;
      }
      return null;
    }

    // ── OBSERVING ─────────────────────────────────────────────────────
    if (pixelDisplacement < kStoppedPixelMovement) {
      state.stoppedFrames++;
    } else {
      state.stoppedFrames = 0;
    }

    if (state.stoppedFrames >= kStoppedFramesThreshold) {
      state.fsm = FsmState.parked;
      return null;
    }

    if (headingRad == null) {
      state.wrongDirectionFrames =
          (state.wrongDirectionFrames - 1).clamp(0, 999);
      return null;
    }

    if (!isWrongWay) {
      state.wrongDirectionFrames =
          (state.wrongDirectionFrames - 1).clamp(0, 999);
      return null;
    }

    state.wrongDirectionFrames++;
    if (state.wrongDirectionFrames >= minWrongFrames) {
      state.fsm = FsmState.candidate;
      state.candidateFrames = 0;
    }

    return null;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static ViolationEvent _buildViolationEvent({
    required TrackFsmState state,
    required Zone zone,
    required String violationType,
    required int frameNum,
    required double? headingRad,
    required bool isCongested,
    required String weather,
  }) {
    final ts = frameNum / 25.0;
    return ViolationEvent(
      trackId: state.trackId,
      vehicleClass: state.vehicleClass,
      violationType: violationType,
      zoneId: zone.zoneId,
      frameNumber: frameNum,
      timestampS: ts,
      confidence: _computeConfidence(state),
      headingDeg: headingRad != null ? headingRad * 180 / math.pi : null,
      bboxPx: List<double>.from(state.bbox),
      isCongested: isCongested,
      weather: weather,
    );
  }

  static double _computeConfidence(TrackFsmState state) {
    final score = (state.candidateFrames / kCandidateConfirmFrames)
        .clamp(0.0, 1.0);
    return (score * 0.5 + state.avgDetConf * 0.5).clamp(0.0, 1.0);
  }
}
