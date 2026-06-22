import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/violation_record.dart';
import '../detectors/plate_detector.dart';
import '../ocr/plate_ocr_service.dart';
import 'violation_storage_service.dart';

class _PendingJob {
  final ViolationRecord record;
  final List<Uint8List> vehicleCrops;
  final Uint8List? frameJpeg;

  _PendingJob({
    required this.record,
    required this.vehicleCrops,
    this.frameJpeg,
  });
}

class ViolationProcessor extends ChangeNotifier {
  // Singleton pattern
  ViolationProcessor._internal();
  static final ViolationProcessor instance = ViolationProcessor._internal();

  final ViolationStorageService _storage = ViolationStorageService();
  final PlateDetector _plateDetector = PlateDetector();
  final PlateOcrService _ocrService = PlateOcrService();

  final Queue<_PendingJob> _queue = Queue<_PendingJob>();
  bool _isProcessing = false;

  final StreamController<void> _onChangeController = StreamController<void>.broadcast();
  Stream<void> get onChange => _onChangeController.stream;

  Future<void> init() async {
    debugPrint('[ViolationProcessor] Initializing...');
    
    // Scan stored records for pending/processing status and re-queues or marks them complete.
    final allRecords = await _storage.loadAll();
    bool updatedAny = false;
    for (final record in allRecords) {
      if (record.status == ViolationStatus.pending || record.status == ViolationStatus.processing) {
        debugPrint('[ViolationProcessor] Found interrupted record ${record.eventId} on startup. Marking complete.');
        final updated = record.copyWith(
          status: ViolationStatus.complete,
          plateNumber: null,
          plateConfidence: null,
        );
        await _storage.save(updated);
        updatedAny = true;
      }
    }
    if (updatedAny) {
      _onChangeController.add(null);
      notifyListeners();
    }
  }

  void enqueue(ViolationRecord record, List<Uint8List> vehicleCrops, Uint8List? frameJpeg) async {
    debugPrint('[ViolationProcessor] Enqueueing job for record ${record.eventId} (crops: ${vehicleCrops.length})');
    
    // Save record as pending immediately
    final pendingRecord = record.copyWith(status: ViolationStatus.pending);
    await _storage.save(pendingRecord);
    _onChangeController.add(null);
    notifyListeners();

    _queue.add(_PendingJob(
      record: pendingRecord,
      vehicleCrops: vehicleCrops,
      frameJpeg: frameJpeg,
    ));

    _processNext();
  }

  Future<void> _processNext() async {
    if (_isProcessing) return;
    if (_queue.isEmpty) return;

    _isProcessing = true;
    final job = _queue.removeFirst();
    debugPrint('[ViolationProcessor] Processing job for record ${job.record.eventId}');

    try {
      // 1. Update record to processing
      var currentRecord = job.record.copyWith(status: ViolationStatus.processing);
      await _storage.save(currentRecord);
      _onChangeController.add(null);
      notifyListeners();

      // Load user settings dynamically before processing plate crops
      try {
        final prefs = await SharedPreferences.getInstance();
        final threshold = prefs.getDouble('plate_conf_threshold') ?? 0.30;
        _plateDetector.confThreshold = threshold;
      } catch (e) {
        debugPrint('[ViolationProcessor] Failed to load plate confidence threshold: $e');
      }

      String? vehicleImagePath;
      if (job.vehicleCrops.isNotEmpty) {
        // Save the best (last) vehicle crop as the vehicle image
        vehicleImagePath = await _storage.saveVehicleImage(
            currentRecord, job.vehicleCrops.last);
      }

      // 2. Run plate YOLO on every vehicle crop → collect all plate chips
      final allPlateChips = <Uint8List>[];
      img.Image? decoded;

      for (final cropJpeg in job.vehicleCrops) {
        decoded = img.decodeImage(cropJpeg);
        if (decoded == null) continue;

        final result = await _plateDetector.detectPlate(
          frameDecoded: decoded,
          vehicleBbox: [
            0, 0,
            decoded.width.toDouble(),
            decoded.height.toDouble(),
          ],
          frameWidth: decoded.width,
          frameHeight: decoded.height,
        );
        allPlateChips.addAll(result.plateChips);
      }

      // 3. Run OCR on all collected plate chips
      String? plateText;
      double? plateConf;
      String? plateImagePath;

      if (allPlateChips.isNotEmpty) {
        final (plate, conf) = await _ocrService.recognizeBestFromBytes(allPlateChips);
        plateText = plate;
        plateConf = conf;

        // Save the best plate chip as plate image (first one)
        final bestChip = allPlateChips.first;
        plateImagePath = await _storage.savePlateImage(currentRecord, bestChip);
      }

      // 4. Update record to complete with plate info + image paths
      final completedRecord = currentRecord.copyWith(
        status: ViolationStatus.complete,
        plateNumber: plateText,
        plateConfidence: plateConf,
        vehicleImagePath: vehicleImagePath,
        plateImagePath: plateImagePath,
      );
      await _storage.save(completedRecord);
      debugPrint('[ViolationProcessor] Completed job for record ${completedRecord.eventId}. Plate: $plateText');
    } catch (e, stack) {
      debugPrint('[ViolationProcessor] Error processing record ${job.record.eventId}: $e\n$stack');
      try {
        final errorRecord = job.record.copyWith(
          status: ViolationStatus.complete,
          plateNumber: null,
          plateConfidence: null,
        );
        await _storage.save(errorRecord);
      } catch (saveErr) {
        debugPrint('[ViolationProcessor] Error trying to save recovery record: $saveErr');
      }
    } finally {
      _onChangeController.add(null);
      notifyListeners();
      _isProcessing = false;
      // Recurse to process the next one
      _processNext();
    }
  }
}
