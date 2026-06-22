import 'track.dart';
import 'hungarian.dart';

/// A detection from the YOLO model for one frame.
class Detection {
  const Detection({
    required this.bbox, // [x1, y1, x2, y2] in pixel coords
    required this.score,
    required this.classId,
    required this.className,
  });

  final List<double> bbox;
  final double score;
  final int classId;
  final String className;
}

/// Pure Dart implementation of the ByteTrack multi-object tracker.
///
/// Reference: "ByteTrack: Multi-Object Tracking by Associating Every
/// Detection Box" (Zhang et al., 2022).
///
/// Two-stage association:
///   Stage 1 — High-confidence detections (score ≥ trackThresh) are matched
///              against confirmed tracks using IoU + Hungarian algorithm.
///   Stage 2 — Low-confidence detections are matched against remaining
///              (unmatched) confirmed tracks.
///   New tracks are initialised from unmatched high-confidence detections.
///   Tracks unseen for > maxTimeLost frames are deleted.
class ByteTracker {
  ByteTracker({
    this.trackThresh = 0.5,
    this.highThresh = 0.6,
    this.matchThresh = 0.8,
    this.trackBuffer = 30,
    this.frameRate = 25,
  }) {
    _maxTimeLost = (trackBuffer * frameRate / 30.0).round();
  }

  /// Score threshold for a detection to be considered a valid track init.
  final double trackThresh;

  /// Score boundary splitting high / low confidence detections.
  final double highThresh;

  /// IoU threshold — matches with IoU < (1 - matchThresh) are rejected.
  final double matchThresh;

  /// Buffer in frames before a lost track is deleted.
  final int trackBuffer;

  final int frameRate;

  late final int _maxTimeLost;

  int _frameId = 0;

  /// Current frame count (read-only access for consumers).
  int get currentFrame => _frameId;

  final List<Track> _trackedTracks = [];
  final List<Track> _lostTracks = [];

  // ---------------------------------------------------------------------------

  /// Process one frame of detections.
  ///
  /// Returns the list of currently active confirmed tracks.
  List<Track> update(List<Detection> detections) {
    _frameId++;

    // ── Split detections ────────────────────────────────────────────────
    final dHigh = detections.where((d) => d.score >= highThresh).toList();
    final dLow = detections
        .where((d) => d.score >= trackThresh && d.score < highThresh)
        .toList();

    // ── Predict existing tracks ─────────────────────────────────────────
    for (final t in _trackedTracks) {
      t.predict();
    }
    for (final t in _lostTracks) {
      t.predict();
    }

    // ── Stage 1: match dHigh vs confirmed tracked tracks ────────────────
    final confirmedTracks = _trackedTracks.where((t) => t.isConfirmed).toList();
    final tentativeTracks = _trackedTracks.where((t) => !t.isConfirmed).toList();

    final matchResult1 = _matchDetections(confirmedTracks, dHigh, matchThresh);
    final List<Track> matchedTracks1 = [];
    final List<Detection> unmatchedDets1 = [];

    for (final m in matchResult1.matches) {
      confirmedTracks[m.trackIdx].update(dHigh[m.detIdx].bbox, dHigh[m.detIdx].score);
      confirmedTracks[m.trackIdx].classId = dHigh[m.detIdx].classId;
      confirmedTracks[m.trackIdx].className = dHigh[m.detIdx].className;
      matchedTracks1.add(confirmedTracks[m.trackIdx]);
    }
    for (final idx in matchResult1.unmatchedDets) {
      unmatchedDets1.add(dHigh[idx]);
    }
    final List<Track> unmatchedTracks1 = [
      ...matchResult1.unmatchedTracks.map((i) => confirmedTracks[i]),
    ];

    // ── Stage 2: match dLow vs unmatched confirmed tracks ───────────────
    final matchResult2 = _matchDetections(unmatchedTracks1, dLow, 0.5);
    final List<Track> matchedTracks2 = [];

    for (final m in matchResult2.matches) {
      unmatchedTracks1[m.trackIdx].update(dLow[m.detIdx].bbox, dLow[m.detIdx].score);
      matchedTracks2.add(unmatchedTracks1[m.trackIdx]);
    }

    // Tracks unmatched in both stages → mark lost
    final remainingUnmatched = matchResult2.unmatchedTracks
        .map((i) => unmatchedTracks1[i])
        .toList();
    for (final t in remainingUnmatched) {
      t.markLost();
    }

    // ── Match tentative tracks against unmatched dHigh detections ────────
    final matchResult3 = _matchDetections(tentativeTracks, unmatchedDets1, matchThresh);
    final List<Detection> stillUnmatchedDets = [];

    for (final m in matchResult3.matches) {
      tentativeTracks[m.trackIdx].update(
          unmatchedDets1[m.detIdx].bbox, unmatchedDets1[m.detIdx].score);
      matchedTracks1.add(tentativeTracks[m.trackIdx]);
    }
    for (final idx in matchResult3.unmatchedDets) {
      stillUnmatchedDets.add(unmatchedDets1[idx]);
    }
    for (final i in matchResult3.unmatchedTracks) {
      tentativeTracks[i].markLost();
    }

    // ── Initialise new tracks from unmatched high-score detections ───────
    final List<Track> newTracks = [];
    for (final det in stillUnmatchedDets) {
      if (det.score >= trackThresh) {
        final kalman = KalmanBoxTracker(det.bbox);
        final t = Track(
          trackId: kalman.trackId,
          bbox: List<double>.from(det.bbox),
          score: det.score,
          classId: det.classId,
          className: det.className,
          kalman: kalman,
        );
        newTracks.add(t);
      }
    }

    // ── Match lost tracks against unmatched high detections ──────────────
    final unmatchedConfirmedLost = [
      ..._lostTracks,
      ...matchResult2.unmatchedTracks.map((i) => unmatchedTracks1[i]),
    ];
    final matchResult4 = _matchDetections(unmatchedConfirmedLost, stillUnmatchedDets, 0.5);

    for (final m in matchResult4.matches) {
      unmatchedConfirmedLost[m.trackIdx].update(
          stillUnmatchedDets[m.detIdx].bbox, stillUnmatchedDets[m.detIdx].score);
      unmatchedConfirmedLost[m.trackIdx].state = TrackState.confirmed;
      matchedTracks2.add(unmatchedConfirmedLost[m.trackIdx]);
    }

    // ── Promote tentatives that have enough hits ─────────────────────────
    _trackedTracks.clear();
    for (final t in [
      ...matchedTracks1,
      ...matchedTracks2,
      ...newTracks,
    ]) {
      if (t.hitStreak >= 3 || t.state == TrackState.confirmed) {
        t.state = TrackState.confirmed;
      }
      if (!t.isRemoved && !t.isLost) {
        _trackedTracks.add(t);
      }
    }

    // ── Update lost tracks list ──────────────────────────────────────────
    _lostTracks.removeWhere((t) => t.isRemoved);
    for (final t in remainingUnmatched) {
      if (t.timeSinceUpdate > _maxTimeLost) {
        t.markRemoved();
      }
      if (!t.isRemoved && !_trackedTracks.contains(t)) {
        _lostTracks.add(t);
      }
    }
    _lostTracks.removeWhere((t) => t.timeSinceUpdate > _maxTimeLost);

    // ── Return all confirmed active tracks ───────────────────────────────
    return _trackedTracks.where((t) => t.isConfirmed).toList();
  }

  // ---------------------------------------------------------------------------

  _AssignmentResult _matchDetections(
    List<Track> tracks,
    List<Detection> dets,
    double iouThresh,
  ) {
    if (tracks.isEmpty || dets.isEmpty) {
      return _AssignmentResult(
        matches: [],
        unmatchedTracks: List.generate(tracks.length, (i) => i),
        unmatchedDets: List.generate(dets.length, (i) => i),
      );
    }

    final trackBoxes = tracks.map((t) => t.kalman.toBbox()).toList();
    final detBoxes = dets.map((d) => d.bbox).toList();
    final costMat = iouCostMatrix(trackBoxes, detBoxes);
    final assignment = hungarianAlgorithm(costMat);

    final matches = <_Match>[];
    final unmatchedTracks = <int>[];
    final unmatchedDets = <int>[];
    final matchedDetSet = <int>{};

    for (int ti = 0; ti < tracks.length; ti++) {
      final di = assignment[ti];
      if (di < 0 || di >= dets.length) {
        unmatchedTracks.add(ti);
        continue;
      }
      final cost = costMat[ti][di];
      if (cost > 1.0 - iouThresh) {
        unmatchedTracks.add(ti);
      } else {
        matches.add(_Match(ti, di));
        matchedDetSet.add(di);
      }
    }
    for (int di = 0; di < dets.length; di++) {
      if (!matchedDetSet.contains(di)) {
        unmatchedDets.add(di);
      }
    }
    return _AssignmentResult(
      matches: matches,
      unmatchedTracks: unmatchedTracks,
      unmatchedDets: unmatchedDets,
    );
  }
}

// ── Data classes ──────────────────────────────────────────────────────────────

class _Match {
  const _Match(this.trackIdx, this.detIdx);
  final int trackIdx;
  final int detIdx;
}

class _AssignmentResult {
  const _AssignmentResult({
    required this.matches,
    required this.unmatchedTracks,
    required this.unmatchedDets,
  });
  final List<_Match> matches;
  final List<int> unmatchedTracks;
  final List<int> unmatchedDets;
}
