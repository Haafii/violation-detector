import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

/// Detector wrapper for the YOLOv11n road segmentation model.
/// Classes:
///   0: divider
///   1: footpath
///   2: road
///   3: side_land
class RoadDetector {
  RoadDetector({
    this.modelPath = 'assets/models/road_yolov11n.tflite',
    double? confThreshold,
  }) : _confThreshold = confThreshold ?? 0.25;

  final String modelPath;
  double _confThreshold;
  double get confThreshold => _confThreshold;
  set confThreshold(double val) => _confThreshold = val;

  YOLO? _yolo;
  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _confThreshold = prefs.getDouble('road_conf_threshold') ?? _confThreshold;
    } catch (e) {
      debugPrint('[RoadDetector] Failed to load confThreshold: $e');
    }
    try {
      _yolo = YOLO(
        modelPath: modelPath,
        task: YOLOTask.segment,
        useGpu: false,
      );
      await _yolo!.loadModel();
      _loaded = true;
      debugPrint('[RoadDetector] Model loaded: $modelPath');
    } catch (e) {
      debugPrint('[RoadDetector] Failed to load model: $e');
    }
  }

  /// Runs the model on raw JPEG bytes.
  /// Returns a [List<YOLOResult>] with correct classIndex and mask data.
  Future<List<YOLOResult>> detectRoad(Uint8List frameJpeg) async {
    await ensureLoaded();
    if (_yolo == null) return [];
    try {
      final raw = await _yolo!.predict(frameJpeg);
      final dets = raw['detections'] as List<dynamic>? ?? [];
      return dets
          .whereType<Map>()
          .map(_parseDetection)
          .where((r) => r != null)
          .cast<YOLOResult>()
          .toList();
    } catch (e) {
      debugPrint('[RoadDetector] Prediction error: $e');
      return [];
    }
  }

  // ── Raw map → YOLOResult ────────────────────────────────────────────────────
  // The raw predict() map uses different keys than YOLOResult.fromMap expects,
  // so we build the object manually from the correct keys.
  YOLOResult? _parseDetection(Map d) {
    try {
      // ── Class: always derive from className (classIndex is hardcoded 0 by native) ──
      final rawName = (d['className'] as String? ?? '').toLowerCase()
          .replaceAll('_', '').replaceAll('-', '').trim();
      final int classIndex;
      final String className;
      switch (rawName) {
        case 'divider':
          classIndex = 0; className = 'divider';
        case 'footpath':
          classIndex = 1; className = 'footpath';
        case 'road':
          classIndex = 2; className = 'road';
        case 'sideland':
          classIndex = 3; className = 'side_land';
        default:
          classIndex = (d['classIndex'] as num? ?? 0).toInt();
          className = d['className'] as String? ?? 'unknown';
      }

      final confidence = (d['confidence'] as num? ?? 0).toDouble();
      if (confidence < confThreshold) return null;

      // ── Bounding box: the raw map uses x1/y1/x2/y2 and x1_norm etc. ──
      final x1 = (d['x1'] as num? ?? 0).toDouble();
      final y1 = (d['y1'] as num? ?? 0).toDouble();
      final x2 = (d['x2'] as num? ?? 0).toDouble();
      final y2 = (d['y2'] as num? ?? 0).toDouble();

      final x1n = (d['x1_norm'] as num? ?? 0).toDouble();
      final y1n = (d['y1_norm'] as num? ?? 0).toDouble();
      final x2n = (d['x2_norm'] as num? ?? 0).toDouble();
      final y2n = (d['y2_norm'] as num? ?? 0).toDouble();

      // Fallback: if normalized box has both left and top == 0, try the
      // keys the 'boxes' list uses (class, className, confidence, x1_norm…)
      final boundingBox = Rect.fromLTRB(x1, y1, x2, y2);
      final normalizedBox = Rect.fromLTRB(x1n, y1n, x2n, y2n);

      // ── Mask: List<List<num>> logits — val > 0 means sigmoid > 0.5 ──
      List<List<double>>? mask;
      if (d['mask'] != null) {
        final rawMask = d['mask'] as List<dynamic>;
        if (rawMask.isNotEmpty) {
          mask = rawMask.map<List<double>>((row) {
            final r = row as List<dynamic>;
            return r.map<double>((v) => (v as num).toDouble()).toList();
          }).toList();
        }
      }

      return YOLOResult(
        classIndex: classIndex,
        className: className,
        confidence: confidence,
        boundingBox: boundingBox,
        normalizedBox: normalizedBox,
        mask: mask,
      );
    } catch (e) {
      debugPrint('[RoadDetector] _parseDetection error: $e');
      return null;
    }
  }

  Future<void> dispose() async {
    await _yolo?.dispose();
    _loaded = false;
  }
}
