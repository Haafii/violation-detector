import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'plate_validator.dart';

/// Wraps Google ML Kit TextRecognizer and applies Indian plate validation.
///
/// Replaces PaddleOCR from the Python system.
/// Call [recognizePlate] with a cropped vehicle image to get the plate string.
class PlateOcrService {
  PlateOcrService()
      : _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  final TextRecognizer _recognizer;
  bool _disposed = false;

  /// Recognise a license plate from a vehicle-crop [ui.Image].
  ///
  /// Returns (plateText, confidence) or (null, null) if no valid plate found.
  Future<(String?, double?)> recognizePlate(ui.Image vehicleCrop) async {
    if (_disposed) return (null, null);
    try {
      final inputImage = await _uiImageToInputImage(vehicleCrop);
      if (inputImage == null) return (null, null);

      final RecognizedText result = await _recognizer.processImage(inputImage);

      // Collect all text lines sorted top-to-bottom
      final lines = <(String, double)>[];
      for (final block in result.blocks) {
        for (final line in block.lines) {
          lines.add((line.text, line.confidence ?? 0.8));
        }
      }
      if (lines.isEmpty) return (null, null);

      // Try best single line + merged lines
      final candidates = <(String, double)>[];

      // Single best line (highest confidence)
      final best = lines.reduce((a, b) => a.$2 >= b.$2 ? a : b);
      final cleaned = baseclean(best.$1);
      for (final cand in generateCandidates(cleaned)) {
        if (validatePlate(cand)) {
          candidates.add((cand, best.$2));
        }
      }

      // Merged lines (for two-row plates)
      if (lines.length > 1) {
        final merged = baseclean(lines.map((l) => l.$1).join());
        final mergedConf = lines.map((l) => l.$2).reduce((a, b) => a > b ? a : b);
        for (final cand in generateCandidates(merged)) {
          if (validatePlate(cand)) {
            candidates.add((cand, mergedConf));
          }
        }
      }

      if (candidates.isEmpty) return (null, null);
      final winner = electBestPlate(candidates);
      final conf = candidates
          .where((c) => c.$1 == winner)
          .map((c) => c.$2)
          .reduce((a, b) => a > b ? a : b);
      return (winner, conf);
    } catch (e) {
      debugPrint('[PlateOCR] Error: $e');
      return (null, null);
    }
  }

  /// Run OCR across multiple vehicle crops and elect the best plate.
  Future<(String?, double?)> recognizeBest(List<ui.Image> crops) async {
    if (crops.isEmpty) return (null, null);
    final allHits = <(String, double)>[];

    // Sort largest crop first (highest resolution → best OCR quality)
    final sorted = [...crops]
      ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));

    for (final crop in sorted) {
      final (plate, conf) = await recognizePlate(crop);
      if (plate != null && conf != null) {
        allHits.add((plate, conf));
      }
    }

    if (allHits.isEmpty) return (null, null);
    final winner = electBestPlate(allHits);
    final conf = allHits
        .where((h) => h.$1 == winner)
        .map((h) => h.$2)
        .reduce((a, b) => a > b ? a : b);
    return (winner, conf);
  }

  /// Run OCR across multiple plate-chip JPEGs (raw bytes) and elect best plate.
  /// This is used by the background plate extraction pipeline.
  Future<(String?, double?)> recognizeBestFromBytes(List<Uint8List> chipJpegs) async {
    if (chipJpegs.isEmpty) return (null, null);
    if (_disposed) return (null, null);

    final allHits = <(String, double)>[];

    for (final jpeg in chipJpegs) {
      try {
        // Decode JPEG → ui.Image → OCR
        final codec = await ui.instantiateImageCodec(jpeg);
        final frame = await codec.getNextFrame();
        final (plate, conf) = await recognizePlate(frame.image);
        if (plate != null && conf != null) {
          allHits.add((plate, conf));
        }
        frame.image.dispose();
      } catch (_) {}
    }

    if (allHits.isEmpty) return (null, null);
    final winner = electBestPlate(allHits);
    final conf = allHits
        .where((h) => h.$1 == winner)
        .map((h) => h.$2)
        .reduce((a, b) => a > b ? a : b);
    return (winner, conf);
  }


  /// Convert [ui.Image] → [InputImage] for ML Kit.
  Future<InputImage?> _uiImageToInputImage(ui.Image image) async {
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;
      final bytes = Uint8List.view(byteData.buffer);

      // Convert RGBA → NV21 (required by ML Kit on Android)
      final nv21 = _rgbaToNv21(bytes, image.width, image.height);

      return InputImage.fromBytes(
        bytes: nv21,
        metadata: InputImageMetadata(
          size: ui.Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.width,
        ),
      );
    } catch (e) {
      debugPrint('[PlateOCR] Image conversion error: $e');
      return null;
    }
  }

  /// Convert RGBA bytes to NV21 (YCbCr 4:2:0) byte array.
  Uint8List _rgbaToNv21(Uint8List rgba, int width, int height) {
    final ySize = width * height;
    final uvSize = (width * height) ~/ 2;
    final nv21 = Uint8List(ySize + uvSize);

    for (int j = 0; j < height; j++) {
      for (int i = 0; i < width; i++) {
        final offset = (j * width + i) * 4;
        final r = rgba[offset].toDouble();
        final g = rgba[offset + 1].toDouble();
        final b = rgba[offset + 2].toDouble();

        // BT.601 luma
        final y = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
        nv21[j * width + i] = y;

        // Chrominance (2×2 subsampling)
        if (j % 2 == 0 && i % 2 == 0) {
          final cb = (-0.169 * r - 0.331 * g + 0.500 * b + 128).round().clamp(0, 255);
          final cr = (0.500 * r - 0.419 * g - 0.081 * b + 128).round().clamp(0, 255);
          final uvIdx = ySize + (j ~/ 2) * width + i;
          if (uvIdx + 1 < nv21.length) {
            nv21[uvIdx] = cr; // NV21: V first, then U
            nv21[uvIdx + 1] = cb;
          }
        }
      }
    }
    return nv21;
  }

  /// Release ML Kit resources. Call when the OCR service is no longer needed.
  Future<void> dispose() async {
    if (!_disposed) {
      _disposed = true;
      await _recognizer.close();
    }
  }
}
