import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../screens/detection_screen.dart' show DetectionBox;

enum HelmetStatus {
  unknown,
  hasHelmet,
  noHelmet,
}

// ─────────────────────────────────────────────────────────────────────────────
// Sliding-window per-track no-helmet confirmation.
// A status is confirmed once >= confirmRatio frames say the same thing
// within the most recent windowSize inference frames.
// ─────────────────────────────────────────────────────────────────────────────
class _HelmetWindow {
  _HelmetWindow({this.windowSize = 10, this.confirmRatio = 0.6});

  final int windowSize;
  final double confirmRatio;

  final Map<int, Queue<HelmetStatus>> _windows = {};
  final Map<int, HelmetStatus> _confirmed = {};

  /// Feed one frame result for [trackId].
  /// Returns true the first time the window confirms a NO HELMET violation.
  bool update(int trackId, HelmetStatus status) {
    if (status == HelmetStatus.unknown) return false;

    // Once a NO HELMET violation is confirmed, we lock it in so it doesn't flip flop
    if (_confirmed[trackId] == HelmetStatus.noHelmet) return false;

    _windows.putIfAbsent(trackId, () => Queue<HelmetStatus>());
    final w = _windows[trackId]!;
    w.addLast(status);
    if (w.length > windowSize) w.removeFirst();
    if (w.length < windowSize) return false;

    final noHelmetRatio =
        w.where((v) => v == HelmetStatus.noHelmet).length / w.length;
    final hasHelmetRatio =
        w.where((v) => v == HelmetStatus.hasHelmet).length / w.length;

    if (noHelmetRatio >= confirmRatio) {
      _confirmed[trackId] = HelmetStatus.noHelmet;
      return true; // Violation newly confirmed
    } else if (hasHelmetRatio >= confirmRatio) {
      _confirmed[trackId] = HelmetStatus.hasHelmet;
    }
    return false;
  }

  HelmetStatus getStatus(int trackId) =>
      _confirmed[trackId] ?? HelmetStatus.unknown;

  void release(int trackId) {
    _windows.remove(trackId);
    // Don't remove from _confirmed — keep the history for de-dup
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HelmetDetector
//
// Responsibilities:
//   1. Given a full camera frame + a vehicle bounding box, crop the rider area
//      (vehicle box padded upwards) and run the helmet YOLO model.
//   2. Return per-frame (noHelmet bool, overlay boxes in full-frame coords).
//   3. Maintain a per-track sliding window for violation confirmation.
// ─────────────────────────────────────────────────────────────────────────────
class HelmetDetector {
  HelmetDetector({
    this.modelPath = 'assets/models/helmet_yolov11n.tflite',
    this.padTopRatio = 0.8,
    double? confThreshold,
    int windowSize = 10,
    double confirmRatio = 0.6,
  }) : _confThreshold = confThreshold ?? 0.35,
       _window = _HelmetWindow(
          windowSize: windowSize,
          confirmRatio: confirmRatio,
        );

  final String modelPath;

  /// How much to extend the crop upward, as a fraction of the box height.
  /// 0.8 means "80% of the vehicle height" is added above the top edge.
  final double padTopRatio;

  double _confThreshold;
  double get confThreshold => _confThreshold;
  set confThreshold(double val) => _confThreshold = val;
  final _HelmetWindow _window;

  YOLO? _yolo;
  bool _loaded = false;

  static const int _inputSize = 320;
  static const int _clsNoHelmet = 1; // class index 1 = no_helmet
  // (class 0 = helmet / with_helmet)

  // ── Model lifecycle ────────────────────────────────────────────────────────
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _confThreshold = prefs.getDouble('helmet_conf_threshold') ?? _confThreshold;
    } catch (e) {
      debugPrint('[HelmetDetector] Failed to load confThreshold: $e');
    }
    try {
      _yolo = YOLO(
          modelPath: modelPath, task: YOLOTask.detect, useGpu: false);
      await _yolo!.loadModel();
      _loaded = true;
      debugPrint('[HelmetDetector] Loaded: $modelPath');
    } catch (e) {
      debugPrint('[HelmetDetector] Load error: $e');
    }
  }

  // ── Core inference ─────────────────────────────────────────────────────────
  /// Run helmet model on a single vehicle crop.
  ///
  /// The crop is padded upward by [padTopRatio] × box-height to capture
  /// the rider's head even when the YOLO vehicle box excludes it.
  ///
  /// Returns:
  ///   - [HelmetStatus]        → what was found in this crop
  ///   - [List<DetectionBox>] → all detections in full-frame pixel coords
  Future<(HelmetStatus, List<DetectionBox>)> hasNoHelmet({
    required Uint8List frameBytes,
    required List<double> bbox,
    required int frameWidth,
    required int frameHeight,
  }) async {
    await _ensureLoaded();
    if (_yolo == null) return (HelmetStatus.unknown, <DetectionBox>[]);

    // Apply upward padding
    final x1 = bbox[0];
    final y1 = bbox[1];
    final x2 = bbox[2];
    final y2 = bbox[3];
    final boxH = y2 - y1;
    final pad = padTopRatio * boxH;

    final cx1 = x1.toInt().clamp(0, frameWidth - 1);
    final cy1 = (y1 - pad).toInt().clamp(0, frameHeight - 1);
    final cx2 = x2.toInt().clamp(0, frameWidth);
    final cy2 = y2.toInt().clamp(0, frameHeight);

    if (cx2 <= cx1 || cy2 <= cy1) return (HelmetStatus.unknown, <DetectionBox>[]);

    try {
      final decoded = img.decodeImage(frameBytes);
      if (decoded == null) return (HelmetStatus.unknown, <DetectionBox>[]);

      final crop = img.copyCrop(decoded,
          x: cx1, y: cy1, width: cx2 - cx1, height: cy2 - cy1);
      final resized =
          img.copyResize(crop, width: _inputSize, height: _inputSize);
      final cropBytes = Uint8List.fromList(img.encodeJpg(resized));

      final resultMap = await _yolo!.predict(cropBytes);
      final detections = resultMap['detections'] as List<dynamic>? ?? [];

      bool foundNoHelmet = false;
      bool foundHelmet = false;
      final boxes = <DetectionBox>[];
      final cw = cx2 - cx1;
      final ch = cy2 - cy1;

      for (final det in detections) {
        final patchedDet = Map<dynamic, dynamic>.from(det as Map);
        final className = (patchedDet['className'] as String? ?? '')
            .toLowerCase()
            .replaceAll('_', '')
            .replaceAll('-', '')
            .replaceAll(' ', '')
            .trim();
        
        int classIndex = 0;
        if (className == 'helmet' || className == 'withhelmet') {
          classIndex = 0;
        } else if (className == 'nohelmet' || className == 'withouthelmet') {
          classIndex = 1;
        } else {
          classIndex = (patchedDet['classIndex'] as num? ?? 0).toInt();
        }
        patchedDet['classIndex'] = classIndex;

        final r = YOLOResult.fromMap(patchedDet);
        if (r.confidence < confThreshold) continue;

        final isNoHelmet = r.classIndex == _clsNoHelmet;
        if (isNoHelmet) {
          foundNoHelmet = true;
        } else {
          foundHelmet = true;
        }

        // Map normalised model coords → full frame pixel coords
        final px1 = cx1 + r.normalizedBox.left * cw;
        final py1 = cy1 + r.normalizedBox.top * ch;
        final px2 = cx1 + r.normalizedBox.right * cw;
        final py2 = cy1 + r.normalizedBox.bottom * ch;

        boxes.add(DetectionBox(
          rect: Rect.fromLTRB(px1, py1, px2, py2),
          label: isNoHelmet ? 'NO HELMET' : 'HELMET',
          confidence: r.confidence,
          color: isNoHelmet
              ? const Color(0xFFFF3B30)
              : const Color(0xFF34C759),
        ));
      }

      HelmetStatus status = HelmetStatus.unknown;
      // Prioritize noHelmet if both are found in the same crop
      if (foundNoHelmet) {
        status = HelmetStatus.noHelmet;
      } else if (foundHelmet) {
        status = HelmetStatus.hasHelmet;
      }

      return (status, boxes);
    } catch (e) {
      debugPrint('[HelmetDetector] Inference error: $e');
      return (HelmetStatus.unknown, <DetectionBox>[]);
    }
  }

  // ── Sliding-window helpers ─────────────────────────────────────────────────
  /// Feed one per-frame inference result into the confirmation window.
  /// Returns true the *first* time the window confirms a NO HELMET violation.
  bool updateWindow(int trackId, HelmetStatus status) =>
      _window.update(trackId, status);

  HelmetStatus getStatus(int trackId) => _window.getStatus(trackId);

  void releaseTrack(int trackId) => _window.release(trackId);

  Future<void> dispose() async {
    await _yolo?.dispose();
  }
}
