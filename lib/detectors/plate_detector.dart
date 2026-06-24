import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../screens/detection_screen.dart' show DetectionBox;

/// Runs the plate YOLO model on a single vehicle crop.
/// Returns:
///   - list of [DetectionBox] for the overlay (in full-frame coordinates)
///   - list of raw JPEG plate chips (for buffering and OCR later)
class PlateDetector {
  PlateDetector({
    this.modelPath = 'assets/models/plate_yolov11n.tflite',
    double? confThreshold,
    this.inputSize = 320,
  }) : _confThreshold = confThreshold ?? 0.30;

  final String modelPath;
  double _confThreshold;
  double get confThreshold => _confThreshold;
  set confThreshold(double val) => _confThreshold = val;
  final int inputSize;

  YOLO? _yolo;
  bool _loaded = false;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _confThreshold = prefs.getDouble('plate_conf_threshold') ?? _confThreshold;
    } catch (e) {
      debugPrint('[PlateDetector] Failed to load confThreshold: $e');
    }
    try {
      _yolo = YOLO(modelPath: modelPath, task: YOLOTask.detect, useGpu: false);
      await _yolo!.loadModel();
      _loaded = true;
      debugPrint('[PlateDetector] Model loaded: $modelPath');
    } catch (e) {
      debugPrint('[PlateDetector] Failed to load model: $e');
    }
  }

  /// Run plate detection on the [frameDecoded] image for a single vehicle bbox.
  ///
  /// [vehicleBbox] is [x1, y1, x2, y2] in full-frame pixel coordinates.
  /// [frameWidth] / [frameHeight] are the full camera frame dimensions.
  ///
  /// Returns:
  ///   - `overlayBoxes` — DetectionBox entries in full-frame coords (for painter)
  ///   - `plateChips`  — raw JPEG bytes of each detected plate region (for OCR)
  Future<({List<DetectionBox> overlayBoxes, List<Uint8List> plateChips})> detectPlate({
    required img.Image frameDecoded,
    required List<double> vehicleBbox,
    required int frameWidth,
    required int frameHeight,
    bool isTwoWheeler = false,
  }) async {
    await _ensureLoaded();
    if (_yolo == null) return (overlayBoxes: <DetectionBox>[], plateChips: <Uint8List>[]);

    final vx1 = vehicleBbox[0].toInt().clamp(0, frameWidth - 1);
    final vy1 = vehicleBbox[1].toInt().clamp(0, frameHeight - 1);
    final vx2 = vehicleBbox[2].toInt().clamp(0, frameWidth);
    final vy2 = vehicleBbox[3].toInt().clamp(0, frameHeight);

    final vw = vx2 - vx1;
    final vh = vy2 - vy1;
    if (vw <= 0 || vh <= 0) return (overlayBoxes: <DetectionBox>[], plateChips: <Uint8List>[]);

    // Crop vehicle from the decoded frame
    final vehicleCrop = img.copyCrop(frameDecoded, x: vx1, y: vy1, width: vw, height: vh);

    // Resize to model input size (keep proportions via pad later if needed)
    final resized = img.copyResize(vehicleCrop, width: inputSize, height: inputSize);
    final inputBytes = Uint8List.fromList(img.encodeJpg(resized));

    try {
      final result = await _yolo!.predict(inputBytes);
      final detections = result['detections'] as List<dynamic>? ?? [];

      final overlayBoxes = <DetectionBox>[];
      final plateChips = <Uint8List>[];

      for (final det in detections) {
        final r = YOLOResult.fromMap(det as Map);
        if (r.confidence < confThreshold) continue;

        // If it's a two-wheeler, avoid false positive license plate detections
        // in the upper head/helmet region of the crop (which has 80% padTopRatio).
        // The top part of the padded crop is the first 80/180 = ~44% of the height.
        if (isTwoWheeler && r.normalizedBox.top < 0.42) {
          debugPrint('[PlateDetector] Filtered out plate candidate in upper region (rider head/helmet): ${r.normalizedBox}');
          continue;
        }

        // Map normalized coords back to full-frame coords
        final px1 = (vx1 + r.normalizedBox.left * vw).clamp(0.0, frameWidth.toDouble());
        final py1 = (vy1 + r.normalizedBox.top * vh).clamp(0.0, frameHeight.toDouble());
        final px2 = (vx1 + r.normalizedBox.right * vw).clamp(0.0, frameWidth.toDouble());
        final py2 = (vy1 + r.normalizedBox.bottom * vh).clamp(0.0, frameHeight.toDouble());

        overlayBoxes.add(DetectionBox(
          rect: Rect.fromLTRB(px1, py1, px2, py2),
          label: 'PLATE',
          confidence: r.confidence,
          color: const Color(0xFF00D4FF),
        ));

        // Crop the plate chip from the original (non-resized) vehicle crop
        final cpx1 = (r.normalizedBox.left * vw).toInt().clamp(0, vw - 1);
        final cpy1 = (r.normalizedBox.top * vh).toInt().clamp(0, vh - 1);
        final cpx2 = (r.normalizedBox.right * vw).toInt().clamp(0, vw);
        final cpy2 = (r.normalizedBox.bottom * vh).toInt().clamp(0, vh);

        final chipW = cpx2 - cpx1;
        final chipH = cpy2 - cpy1;
        if (chipW > 4 && chipH > 4) {
          final chip = img.copyCrop(vehicleCrop, x: cpx1, y: cpy1, width: chipW, height: chipH);
          // Upscale small plates for better OCR
          final upscaled = (chipW < 200 || chipH < 60)
              ? img.copyResize(chip, width: 400, interpolation: img.Interpolation.cubic)
              : chip;
          plateChips.add(Uint8List.fromList(img.encodeJpg(upscaled, quality: 95)));
        }
      }

      return (overlayBoxes: overlayBoxes, plateChips: plateChips);
    } catch (e) {
      debugPrint('[PlateDetector] Inference error: $e');
      return (overlayBoxes: <DetectionBox>[], plateChips: <Uint8List>[]);
    }
  }

  Future<void> dispose() async {
    await _yolo?.dispose();
  }
}
