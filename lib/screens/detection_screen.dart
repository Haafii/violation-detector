import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'; // for compute()
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

import '../detectors/helmet_detector.dart';
import '../detectors/road_detector.dart';
import 'manual_heading_screen.dart';
import 'manual_polygon_screen.dart';
import '../fsm/fsm_state.dart';
import '../fsm/wrongside_pipeline.dart';
import '../fsm/zone_topology.dart';
import '../models/violation_record.dart';
import '../services/auto_calibration_service.dart';
import '../services/violation_processor.dart';
import '../services/violation_storage_service.dart';
import '../tracker/byte_tracker.dart';
import '../widgets/violation_overlay_painter.dart';


// ─────────────────────────────────────────────────────────────────────────────
// Per-track vehicle crop buffer (3-4 crops from different frames).
// Stores raw JPEG bytes of the vehicle region (with upward padding for
// two-wheelers so the rider's head is included in every crop).
// ─────────────────────────────────────────────────────────────────────────────
class _VehicleCropBuffer {
  static const int kMaxCrops = 4;

  final List<Uint8List> crops = [];

  bool get isFull => crops.length >= kMaxCrops;

  void push(Uint8List jpeg) {
    if (!isFull) crops.add(jpeg);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Isolate helpers — all fields must be sendable across isolate boundaries
// (only primitives, Uint8List, List, etc.)
// ─────────────────────────────────────────────────────────────────────────────
class _TrackArg {
  const _TrackArg({
    required this.trackId,
    required this.vehicleClass,
    required this.bbox,
  });
  final int trackId;
  final String vehicleClass;
  final List<double> bbox;
}

class _CropArgs {
  const _CropArgs({required this.frameJpeg, required this.tracks});
  final Uint8List frameJpeg;
  final List<_TrackArg> tracks;
}

class _CropResult {
  const _CropResult({required this.trackId, required this.cropJpeg});
  final int trackId;
  final Uint8List cropJpeg;
}



/// Top-level function: runs in a background isolate via compute().
/// Decodes the JPEG once, rotates if needed, crops each track's vehicle region.
List<_CropResult> _cropAllVehicles(_CropArgs args) {
  final results = <_CropResult>[];

  // Decode the JPEG
  img.Image? decoded = img.decodeImage(args.frameJpeg);
  if (decoded == null) return results;

  // Rotate 90° CCW if landscape (Android portrait-mode camera outputs landscape)
  if (decoded.width > decoded.height) {
    decoded = img.copyRotate(decoded, angle: 90);
  }

  final imgW = decoded.width;
  final imgH = decoded.height;

  for (final track in args.tracks) {
    final isTwoWheeler =
        track.vehicleClass == 'motorcycle' || track.vehicleClass == 'two-wheeler';
    double x1 = track.bbox[0];
    double y1 = track.bbox[1];
    double x2 = track.bbox[2];
    double y2 = track.bbox[3];

    // Upward padding for two-wheelers to capture rider's head
    if (isTwoWheeler) {
      final boxH = y2 - y1;
      y1 = (y1 - boxH * 0.8).clamp(0, imgH.toDouble());
    }

    final cx1 = x1.toInt().clamp(0, imgW - 1);
    final cy1 = y1.toInt().clamp(0, imgH - 1);
    final cx2 = x2.toInt().clamp(0, imgW);
    final cy2 = y2.toInt().clamp(0, imgH);

    if (cx2 <= cx1 || cy2 <= cy1) continue;

    final crop = img.copyCrop(decoded,
        x: cx1, y: cy1, width: cx2 - cx1, height: cy2 - cy1);
    results.add(_CropResult(
      trackId: track.trackId,
      cropJpeg: Uint8List.fromList(img.encodeJpg(crop, quality: 95)),
    ));
  }
  return results;
}

/// Rotates landscape JPEG to portrait (90 degrees clockwise).
Uint8List _rotateJpegToPortrait(Uint8List jpegBytes) {
  final image = img.decodeImage(jpegBytes);
  if (image == null) return jpegBytes;
  if (image.width > image.height) {
    final rotated = img.copyRotate(image, angle: 90);
    return Uint8List.fromList(img.encodeJpg(rotated));
  }
  return jpegBytes;
}

enum _CalibState {
  idle,            // waiting for first frame to capture
  capturing,       // YOLOView live; waiting to capture a frame
  analysing,       // running road seg on frozen frame (loading overlay)
  confirmingZones, // showing frozen frame + polygon; awaiting Accept/Reject
  observing,       // vehicle model loaded; watching traffic to auto-detect heading
  confirmingDirections, // showing frozen frame + zones + auto-detected heading arrows; awaiting Accept/Retry
  headingSetup,    // navigated to ManualHeadingScreen (awaiting return)
  detecting,       // normal violation detection
}

// ─────────────────────────────────────────────────────────────────────────────
// DetectionScreen
// ─────────────────────────────────────────────────────────────────────────────
class DetectionScreen extends StatefulWidget {
  const DetectionScreen({super.key, this.topology, this.frameBytes});
  final ZoneTopology? topology;
  final Uint8List? frameBytes;

  @override
  State<DetectionScreen> createState() => _DetectionScreenState();
}

class _DetectionScreenState extends State<DetectionScreen>
    with TickerProviderStateMixin {
  // ── Pipeline ─────────────────────────────────────────────────────────────
  late WrongSidePipeline _pipeline;
  late ZoneTopology _topology;
  bool _pipelineReady = false;

  // ── Services ─────────────────────────────────────────────────────────────
  final ViolationStorageService _storage = ViolationStorageService();
  final HelmetDetector _helmetDetector = HelmetDetector();
  final AutoCalibrationService _calibrationService = AutoCalibrationService();

  // ── Auto-Calibration state ────────────────────────────────────────────────
  _CalibState _calibState = _CalibState.idle;
  String _currentModelPath = 'assets/models/vehicle_yolov11n.tflite';
  YOLOTask _currentTask = YOLOTask.detect;
  bool _includeMasks = false;
  bool _isAnalysing = false;
  bool _isModelLoading = true;
  bool _firstFrameReceived = false;
  String? _loadedModelPath;

  Uint8List? _frozenFrame;
  ZoneTopology? _detectedTopology;

  // ── Observing phase (Phase 2) ────────────────────────────────────────────
  ZoneTopology? _phase1Topology;       // zones from road-seg, awaiting heading
  Timer? _observingTimer;
  int _observingSecondsLeft = 0;
  int _observingTotalSeconds = 20;

  final RoadDetector _roadDetector = RoadDetector();

  double _vehicleTrackThresh = 0.4;
  double _vehicleHighThresh = 0.5;


  // ── YOLO controller ──────────────────────────────────────────────────────
  late final YOLOViewController _yoloController;
  bool _overlaysHidden = false;
  int _hideOverlaysCounter = 0;

  // ── Frame counters ────────────────────────────────────────────────────────
  int _frameNum = 0;
  int _totalViolations = 0;

  // ── Camera dimensions (updated from JPEG header on first frame) ──────────
  int _frameWidth  = 720;
  int _frameHeight = 1280;

  // ── Latest raw camera JPEG ────────────────────────────────────────────────
  Uint8List? _latestFrame;
  List<YOLOResult>? _latestDetections;

  // ── Per-track vehicle crop buffers (3-4 crops each) ───────────────────────
  // Populated every cropEvery-th frame; flushed when track goes stale.
  final Map<int, _VehicleCropBuffer> _vehicleBuffers = {};
  static const int _cropEveryNFrames = 8; // ~2 fps at 15fps camera
  int _cropFrameCounter = 0;

  // ── Per-track helmet sliding window ───────────────────────────────────────
  final Map<int, HelmetStatus> _helmetStatusMap = {};
  int _helmetFrameCounter = 0;
  static const int _helmetEveryNFrames = 15;

  // ── Violation flash ───────────────────────────────────────────────────────
  bool _flashVisible = false;
  Timer? _flashTimer;
  late AnimationController _flashAnim;
  final Queue<ViolationRecord> _recentViolations = Queue();

  // ── De-dup (trackId, violationType) ──────────────────────────────────────
  final Set<(int, String)> _processedTracks = {};

  // ── Scale model pixels → screen pixels ───────────────────────────────────
  double _scaleX = 1.0, _scaleY = 1.0;

  // ─────────────────────────────────────────────────────────────────────────
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _yoloController = YOLOViewController();
    _flashAnim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _initPipeline();
    }
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _observingTimer?.cancel();
    _flashAnim.dispose();
    _helmetDetector.dispose();
    _roadDetector.dispose();
    super.dispose();
  }

  // ── Normalized Topology & Scaling ─────────────────────────────────────────
  ZoneTopology? _normalizedTopology;

  ZoneTopology _normalizeIfNeeded(ZoneTopology original) {
    bool isAbsolute = false;
    for (final z in original.zones) {
      for (final p in z.polygon) {
        if (p.dx > 1.0 || p.dy > 1.0) {
          isAbsolute = true;
          break;
        }
      }
      if (isAbsolute) break;
    }
    
    if (!isAbsolute) return original;
    
    debugPrint('[Topology] Normalizing legacy absolute topology of size 1080x1920 to 0.0-1.0 space');
    return ZoneTopology(
      zones: original.zones.map((z) => Zone(
        zoneId: z.zoneId,
        zoneType: z.zoneType,
        polygon: z.polygon.map((p) => Offset(p.dx / 1080.0, p.dy / 1920.0)).toList(),
        legalHeadingDeg: z.legalHeadingDeg,
        headingToleranceDeg: z.headingToleranceDeg,
        vehicleClasses: z.vehicleClasses,
      )).toList(),
    );
  }

  ZoneTopology _scaleTopology(ZoneTopology normalized, double w, double h) {
    return ZoneTopology(
      zones: normalized.zones.map((z) => Zone(
        zoneId: z.zoneId,
        zoneType: z.zoneType,
        polygon: z.polygon.map((p) => Offset(p.dx * w, p.dy * h)).toList(),
        legalHeadingDeg: z.legalHeadingDeg,
        headingToleranceDeg: z.headingToleranceDeg,
        vehicleClasses: z.vehicleClasses,
      )).toList(),
    );
  }

  /// Normalize using the ACTUAL current frame dimensions.
  /// Used for topologies produced by auto-calibration (pixel space = _frameWidth x _frameHeight).
  ZoneTopology _normalizeByActualFrame(ZoneTopology original) {
    bool isAbsolute = false;
    for (final z in original.zones) {
      for (final p in z.polygon) {
        if (p.dx > 1.0 || p.dy > 1.0) {
          isAbsolute = true;
          break;
        }
      }
      if (isAbsolute) break;
    }

    if (!isAbsolute) return original;

    final fw = _frameWidth.toDouble();
    final fh = _frameHeight.toDouble();
    debugPrint('[Topology] Normalizing auto-calib topology by actual frame ${fw}x$fh');
    return ZoneTopology(
      zones: original.zones.map((z) => Zone(
        zoneId: z.zoneId,
        zoneType: z.zoneType,
        polygon: z.polygon.map((p) => Offset(p.dx / fw, p.dy / fh)).toList(),
        legalHeadingDeg: z.legalHeadingDeg,
        headingToleranceDeg: z.headingToleranceDeg,
        vehicleClasses: z.vehicleClasses,
        needsManualHeading: z.needsManualHeading,
      )).toList(),
    );
  }

  void _recreatePipelineWithResolution(double w, double h) {
    if (_normalizedTopology == null) return;
    _topology = _scaleTopology(_normalizedTopology!, w, h);
    _pipeline = WrongSidePipeline(
      topology: _topology,
      fps: 15,
      trackThresh: _vehicleTrackThresh,
      highThresh: _vehicleHighThresh,
    );
    debugPrint('[Pipeline] Pipeline updated with scaled topology for resolution ${w}x$h');
  }

  // ── Pipeline init ─────────────────────────────────────────────────────────
  Future<void> _initPipeline() async {
    final prefs = await SharedPreferences.getInstance();
    _vehicleTrackThresh = prefs.getDouble('vehicle_track_threshold') ?? 0.4;
    _vehicleHighThresh = prefs.getDouble('vehicle_high_threshold') ?? 0.5;

    _firstFrameReceived = false;

    // Load and assign detector confidence thresholds once at screen startup
    final helmetConf = prefs.getDouble('helmet_conf_threshold') ?? 0.35;
    final roadConf = prefs.getDouble('road_conf_threshold') ?? 0.25;
    _helmetDetector.confThreshold = helmetConf;
    _roadDetector.confThreshold = roadConf;

    _observingTotalSeconds = (prefs.getInt('calibration_duration_seconds') ?? 20).clamp(20, 60);

    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final useSaved = args?['useSaved'] as bool? ?? false;

    if (widget.topology != null) {
      _calibState = _CalibState.detecting;
      _currentModelPath = 'assets/models/vehicle_yolov11n.tflite';
      _currentTask = YOLOTask.detect;
      _includeMasks = false;
      _isModelLoading = true;
      _loadedModelPath = null;
      _normalizedTopology = _normalizeIfNeeded(widget.topology!);
      _recreatePipelineWithResolution(_frameWidth.toDouble(), _frameHeight.toDouble());
      _pipelineReady = true;
      if (mounted) setState(() {});
      return;
    }

    if (useSaved) {
      final stored = await _storage.loadTopology();
      if (stored != null) {
        // Normal detection mode with saved calibration
        _calibState = _CalibState.detecting;
        _currentModelPath = 'assets/models/vehicle_yolov11n.tflite';
        _currentTask = YOLOTask.detect;
        _includeMasks = false;
        _isModelLoading = true;
        _loadedModelPath = null;
        final rawTopology = ZoneTopology.fromJson(stored);
        _normalizedTopology = _normalizeIfNeeded(rawTopology);
        _recreatePipelineWithResolution(_frameWidth.toDouble(), _frameHeight.toDouble());
        _pipelineReady = true;
        if (mounted) setState(() {});
        return;
      }
    }

    // Otherwise, start fresh Auto-Calibration!
    _calibState = _CalibState.capturing;
    _currentModelPath = 'assets/models/road_yolov11n.tflite';
    _currentTask = YOLOTask.segment;
    _includeMasks = true;
    _isAnalysing = false;
    _isModelLoading = true;
    _loadedModelPath = null;
    _calibrationService.reset();
    
    _topology = ZoneTopology(zones: []);
    _detectedTopology = null;
    _frozenFrame = null;
    _pipeline = WrongSidePipeline(
      topology: _topology,
      fps: 15,
      trackThresh: _vehicleTrackThresh,
      highThresh: _vehicleHighThresh,
    );
    _pipelineReady = true;
    
    debugPrint('[Calibration] Starting fresh photo-based auto-calibration.');
    if (mounted) setState(() {});
  }

  Future<void> _captureAndAnalyse(Uint8List rawBytes, List<YOLOResult>? landscapeDetections) async {
    try {
      // 1. Rotate to portrait in background isolate first before freezing/drawing landscape
      final rotatedBytes = await compute(_rotateJpegToPortrait, rawBytes);

      setState(() {
        _calibState = _CalibState.analysing;
        _frozenFrame = rotatedBytes;
      });

      // 2. Decode info to update portrait dimensions
      final info = img.findDecoderForData(rotatedBytes)?.startDecode(rotatedBytes);
      if (info != null && info.width > 0 && info.height > 0) {
        _frameWidth = info.width;
        _frameHeight = info.height;
        debugPrint('[Calibration] Dims updated from rotated frame: ${_frameWidth}x$_frameHeight');
      }

      final List<YOLOResult> results;
      if (landscapeDetections != null && landscapeDetections.isNotEmpty) {
        debugPrint('[Calibration] Rotating ${landscapeDetections.length} live stream masks.');
        results = landscapeDetections.map((r) {
          final rotatedMask = r.mask != null ? _rotateMask90Clockwise(r.mask!) : null;
          return YOLOResult(
            classIndex: r.classIndex,
            className: r.className,
            confidence: r.confidence,
            boundingBox: r.boundingBox,
            normalizedBox: r.normalizedBox,
            mask: rotatedMask,
          );
        }).toList();
      } else {
        // Fallback: run road segmentation on portrait frame using RoadDetector
        debugPrint('[Calibration] No live detections available, falling back to RoadDetector prediction.');
        results = await _roadDetector.detectRoad(rotatedBytes);
      }
      debugPrint('[Calibration] Resolved ${results.length} segments for auto-calibration.');

      // 4. Finalize calibration from this single frame
      final topology = _calibrationService.finalizeFromSingleFrame(
        results: results,
        frameWidth: _frameWidth.toDouble(),
        frameHeight: _frameHeight.toDouble(),
      );

      setState(() {
        _detectedTopology = topology;
        _calibState = _CalibState.confirmingZones;
      });
    } catch (e) {
      debugPrint('[Calibration] Analysis error: $e');
      setState(() {
        _calibState = _CalibState.confirmingZones;
        _detectedTopology = ZoneTopology(zones: []);
      });
    } finally {
      _isAnalysing = false;
    }
  }

  List<List<double>> _rotateMask90Clockwise(List<List<double>> src) {
    if (src.isEmpty || src[0].isEmpty) return src;
    final h = src.length;
    final w = src[0].length;
    final dst = List.generate(w, (_) => List.filled(h, 0.0));
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        dst[x][h - 1 - y] = src[y][x];
      }
    }
    return dst;
  }

  void _onRescan() {
    setState(() {
      _detectedTopology = null;
      _frozenFrame = null;
      _isAnalysing = false;
      _calibState = _CalibState.capturing;
      _currentModelPath = 'assets/models/road_yolov11n.tflite';
      _currentTask = YOLOTask.segment;
      _includeMasks = true;
      _hideOverlaysCounter = 0;
      _overlaysHidden = false;
      _latestDetections = null;
      _isModelLoading = true;
      _loadedModelPath = null;
      _firstFrameReceived = false;
    });
  }

  void _onCapturePressed() {
    if (_latestFrame == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for stable camera feed...')),
      );
      return;
    }
    if (_isAnalysing) return;

    final snapFrame = _latestFrame!;
    final snapDets = _latestDetections;

    setState(() {
      _isAnalysing = true;
      _calibState = _CalibState.analysing;
    });
    _captureAndAnalyse(snapFrame, snapDets);
  }

  Future<void> _onManualDraw() async {
    final Uint8List? bgFrame = _frozenFrame ?? _latestFrame;
    if (bgFrame == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for stable camera feed...')),
      );
      return;
    }

    final Uint8List portraitFrame;
    if (_frozenFrame == null) {
      setState(() {
        _isAnalysing = true;
      });
      portraitFrame = await compute(_rotateJpegToPortrait, bgFrame);
      setState(() {
        _isAnalysing = false;
        _frozenFrame = portraitFrame;
      });
    } else {
      portraitFrame = _frozenFrame!;
    }

    if (!mounted) return;

    // Save previous state to restore if they cancel manual drawing
    final prevState = _calibState;
    setState(() {
      _calibState = _CalibState.analysing; // This unmounts YOLOView camera!
    });

    final result = await Navigator.push<ZoneTopology>(
      context,
      MaterialPageRoute(
        builder: (context) => ManualPolygonScreen(
          backgroundImage: portraitFrame,
          frameWidth: _frameWidth.toDouble(),
          frameHeight: _frameHeight.toDouble(),
        ),
      ),
    );

    if (!mounted) return;

    if (result != null) {
      // Transition to Phase 2 (Observing) to automatically detect traffic directions on the manually drawn zones!
      setState(() {
        _phase1Topology = result;
      });
      _startObservingPhase();
    } else {
      // Restore previous state so camera turns back on
      setState(() {
        _calibState = prevState;
      });
    }
  }

  Future<void> _onAcceptZones() async {
    if (_detectedTopology == null || _frozenFrame == null) return;

    final roadZones = _detectedTopology!.zones.where((z) => z.zoneType == ZoneType.road).toList();

    if (roadZones.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No road lanes detected to orient. Please draw manually.')),
      );
      _onManualDraw();
      return;
    }

    // Kick off Phase 2: observe traffic to auto-detect headings
    _phase1Topology = _detectedTopology;
    _startObservingPhase();
  }

  Future<void> _startObservingPhase() async {
    // Load the calibration duration from SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final duration = (prefs.getInt('calibration_duration_seconds') ?? 20).clamp(10, 120);

    _calibrationService.reset();

    if (!mounted) return;
    setState(() {
      _observingTotalSeconds = duration;
      _observingSecondsLeft = duration;
      _calibState = _CalibState.observing;
      _isModelLoading = true;
      _loadedModelPath = null;
      _firstFrameReceived = false;
      // Switch YOLOView to vehicle detection model
      _currentModelPath = 'assets/models/vehicle_yolov11n.tflite';
      _currentTask = YOLOTask.detect;
      _includeMasks = false;
    });

    _observingTimer?.cancel();
    _observingTimer = null;

    debugPrint('[Calibration] Phase 2: observing traffic initialized, waiting for model load...');
  }

  void _startObservingTimer() {
    _observingTimer?.cancel();
    _observingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onObservingTimerTick();
    });
    debugPrint('[Calibration] Phase 2: observing timer started.');
  }

  void _onObservingTimerTick() {
    if (!mounted) return;
    if (_observingSecondsLeft <= 1) {
      _observingTimer?.cancel();
      _observingTimer = null;
      _onObservingTimerExpired();
    } else {
      setState(() => _observingSecondsLeft--);
    }
  }

  Future<void> _onObservingTimerExpired() async {
    if (_phase1Topology == null) return;

    debugPrint('[Calibration] Phase 2 complete. Assigning headings from observed tracks...');

    final finalTopology = _calibrationService.assignHeadingsToZones(
      _phase1Topology!.zones,
    );

    final zonesNeedingHeading =
        finalTopology.zones.where((z) => z.needsManualHeading).toList();

    if (zonesNeedingHeading.isEmpty) {
      // All headings resolved automatically — transition to direction confirmation overlay!
      debugPrint('[Calibration] All headings auto-detected. Transitioning to direction confirmation.');
      final rawFrame = _latestFrame;
      if (rawFrame != null) {
        final rotatedBytes = await compute(_rotateJpegToPortrait, rawFrame);
        final info = img.findDecoderForData(rotatedBytes)?.startDecode(rotatedBytes);
        if (info != null && info.width > 0 && info.height > 0) {
          _frameWidth = info.width;
          _frameHeight = info.height;
          debugPrint('[Calibration] Dims updated from rotated frame: ${_frameWidth}x$_frameHeight');
        }
        setState(() {
          _frozenFrame = rotatedBytes;
          _detectedTopology = finalTopology;
          _calibState = _CalibState.confirmingDirections;
        });
      } else {
        setState(() {
          _detectedTopology = finalTopology;
          _calibState = _CalibState.confirmingDirections;
        });
      }
    } else {
      // Fallback: open ManualHeadingScreen for zones that still need it
      debugPrint(
          '[Calibration] ${zonesNeedingHeading.length} zone(s) need manual heading. Opening fallback screen.');
      if (!mounted) return;
      setState(() {
        _calibState = _CalibState.headingSetup;
      });

      final result = await Navigator.push<ZoneTopology>(
        context,
        MaterialPageRoute(
          builder: (context) => ManualHeadingScreen(
            flaggedZones: zonesNeedingHeading,
            allZones: finalTopology.zones,
            backgroundImage: _frozenFrame!,
            frameWidth: _frameWidth.toDouble(),
            frameHeight: _frameHeight.toDouble(),
          ),
        ),
      );

      if (result != null && mounted) {
        _finishCalibration(result);
      } else if (mounted) {
        // User backed out of heading screen — go back to confirmingZones
        setState(() {
          _calibState = _CalibState.confirmingZones;
        });
      }
    }
  }

  Future<void> _finishCalibration(ZoneTopology completedTopology) async {
    setState(() {
      _pipelineReady = false;
    });

    try {
      // Normalize to 0-1 space using the actual current frame dimensions.
      // We save the NORMALIZED topology so that "Use Active" always loads 0-1 coords,
      // regardless of the resolution used during calibration.
      _normalizedTopology = _normalizeByActualFrame(completedTopology);
      await _storage.saveTopology(_normalizedTopology!.toJson());

      // Re-initialize pipeline (scale normalized 0-1 back to current frame pixel space).
      _topology = completedTopology;
      _recreatePipelineWithResolution(_frameWidth.toDouble(), _frameHeight.toDouble());
      
      setState(() {
        _calibState = _CalibState.detecting;
        _detectedTopology = null;
        _frozenFrame = null;
        _pipelineReady = true;
      });
      debugPrint('[Calibration] Calibration completed and saved!');
    } catch (e) {
      debugPrint('[Calibration] Finish calibration error: $e');
      setState(() {
        _calibState = _CalibState.confirmingZones;
        _pipelineReady = true;
      });
    }
  }


  // ─────────────────────────────────────────────────────────────────────────
  // YOLO streaming callback — runs on every camera frame
  // ─────────────────────────────────────────────────────────────────────────
  void _onStreamingData(Map<String, dynamic> data) {
    if (!_pipelineReady) return;

    final showNative = _currentTask == YOLOTask.segment;

    // Hide native overlays once controller is ready (unless segmenting)
    if (!_overlaysHidden && _yoloController.isInitialized) {
      _yoloController.setShowOverlays(showNative);
      _overlaysHidden = true;
    }

    if (_hideOverlaysCounter > 0 && _yoloController.isInitialized) {
      _yoloController.setShowOverlays(showNative);
      _hideOverlaysCounter--;
    }

    if (data['originalImage'] != null) {
      final bytes = data['originalImage'] as Uint8List;
      _latestFrame = bytes;

      if (data['detections'] != null && _calibState == _CalibState.capturing) {
        final dets = data['detections'] as List;
        _latestDetections = dets.map((d) => YOLOResult.fromMap(d as Map)).toList();
      }

      if (!_firstFrameReceived && _loadedModelPath == _currentModelPath) {
        _firstFrameReceived = true;
        _isModelLoading = false;
        debugPrint('[Frame] First camera stream frame received for current model $_loadedModelPath, clearing loading HUD.');
        if (_calibState == _CalibState.observing) {
          _startObservingTimer();
        }
        if (mounted) {
          setState(() {});
        }
      }

      // Read actual JPEG resolution once.
      // Swap width/height if landscape to get portrait dimensions.
      if (_frameWidth == 720) {
        final info = img.findDecoderForData(bytes)?.startDecode(bytes);
        if (info != null && info.width > 0 && info.height > 0) {
          int newW, newH;
          if (info.width > info.height) {
            newW = info.height;
            newH = info.width;
          } else {
            newW = info.width;
            newH = info.height;
          }
          if (newW != _frameWidth || newH != _frameHeight) {
            _frameWidth = newW;
            _frameHeight = newH;
            debugPrint('[Frame] Portrait-corrected dims updated: ${_frameWidth}x$_frameHeight');
            _recreatePipelineWithResolution(_frameWidth.toDouble(), _frameHeight.toDouble());
          }
        }
      }
    }

    if (data['detections'] != null &&
        (_calibState == _CalibState.detecting ||
            _calibState == _CalibState.observing)) {
      final dets = data['detections'] as List;
      final results = dets.map((d) => YOLOResult.fromMap(d as Map)).toList();
      _onResult(results);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Per-frame update
  // ─────────────────────────────────────────────────────────────────────────
  void _onResult(List<YOLOResult> results) {
    _frameNum++;
    final ts = _frameNum / 15.0;

    // ── Phase 2 observing: feed vehicle headings into calibration service ──
    if (_calibState == _CalibState.observing) {
      final detections = results.map((r) => Detection(
            bbox: [
              r.normalizedBox.left   * _frameWidth,
              r.normalizedBox.top    * _frameHeight,
              r.normalizedBox.right  * _frameWidth,
              r.normalizedBox.bottom * _frameHeight,
            ],
            score: r.confidence,
            classId: r.classIndex,
            className: r.className,
          )).toList();

      _pipeline.updateDetections(detections, _frameNum, ts);

      // Feed every active track's heading + position into the calibration service
      for (final entry in _pipeline.trackStates.entries) {
        final state = entry.value;
        final b = state.bbox;
        if (b.length == 4) {
          final centroid = Offset((b[0] + b[2]) / 2, (b[1] + b[3]) / 2);
          _calibrationService.addVehicleTrackPoint(entry.key, centroid);
        }
        if (state.headingRad != null) {
          _calibrationService.addVehicleHeading(entry.key, state.headingRad!);
        }
      }

      if (mounted) setState(() {});
      return;
    }

    if (_calibState != _CalibState.detecting) return;

    // Normal violation detection mode
    final detections = results.map((r) => Detection(
          bbox: [
            r.normalizedBox.left   * _frameWidth,
            r.normalizedBox.top    * _frameHeight,
            r.normalizedBox.right  * _frameWidth,
            r.normalizedBox.bottom * _frameHeight,
          ],
          score: r.confidence,
          classId: r.classIndex,
          className: r.className,
        )).toList();

    final events = _pipeline.updateDetections(detections, _frameNum, ts);

    for (final event in events) {
      final key = (event.trackId, event.violationType);
      if (_processedTracks.contains(key)) continue;
      _processedTracks.add(key);
      _handleViolation(event);
    }

    _cropFrameCounter++;
    if (_cropFrameCounter % _cropEveryNFrames == 0 && _latestFrame != null) {
      _cropVehiclesIntoBuffers(_latestFrame!);
    }

    _helmetFrameCounter++;
    if (_helmetFrameCounter % _helmetEveryNFrames == 0) {
      _runHelmetCheck();
    }

    if (mounted) setState(() {});
  }


  // ─────────────────────────────────────────────────────────────────────────
  // Crop every active vehicle from the current frame and push into its buffer.
  // Two-wheelers get upward padding so the rider's head is included.
  //
  // IMPORTANT: The heavy JPEG decode + rotate + crop work is dispatched to a
  // background compute isolate so it never blocks the YOLO inference thread.
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _cropVehiclesIntoBuffers(Uint8List frameJpeg) async {
    // Build snapshot of tracks that still need crops (not full yet)
    final snapshot = <int, ({String vehicleClass, List<double> bbox})>{};
    for (final e in _pipeline.trackStates.entries) {
      final buf = _vehicleBuffers.putIfAbsent(e.key, () => _VehicleCropBuffer());
      if (!buf.isFull) {
        snapshot[e.key] = (vehicleClass: e.value.vehicleClass, bbox: e.value.bbox);
      }
    }
    if (snapshot.isEmpty) return;

    // Prune stale buffers
    final activeIds = _pipeline.trackStates.keys.toSet();
    _vehicleBuffers.removeWhere((id, _) {
      if (!activeIds.contains(id)) {
        _helmetDetector.releaseTrack(id);
        _helmetStatusMap.remove(id);
        return true;
      }
      return false;
    });

    // Build args for the background isolate
    final args = _CropArgs(
      frameJpeg: frameJpeg,
      tracks: snapshot.entries
          .map((e) => _TrackArg(
                trackId: e.key,
                vehicleClass: e.value.vehicleClass,
                bbox: e.value.bbox,
              ))
          .toList(),
    );

    // Run decode + rotate + crop in a background isolate so the YOLO
    // inference thread is never blocked by heavy image processing.
    final results = await compute(_cropAllVehicles, args);

    // Push results into per-track buffers on the main isolate
    for (final r in results) {
      final buf = _vehicleBuffers[r.trackId];
      if (buf != null && !buf.isFull) {
        buf.push(r.cropJpeg);
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Helmet check using buffered vehicle crops (two-wheelers only).
  // Runs the model on the most recent crop and updates the sliding window.
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _runHelmetCheck() async {
    for (final entry in _pipeline.trackStates.entries) {
      final tid = entry.key;
      final state = entry.value;
      final vehicleClass = state.vehicleClass;

      if (vehicleClass != 'motorcycle' && vehicleClass != 'two-wheeler') continue;
      if (_helmetDetector.getStatus(tid) == HelmetStatus.noHelmet) continue;

      final buf = _vehicleBuffers[tid];
      if (buf == null || buf.crops.isEmpty) continue;

      // latestCrop is already the padded vehicle JPEG.
      // Decode it to get the true pixel dimensions for the bbox.
      final latestCrop = buf.crops.last;
      HelmetStatus frameStatus = HelmetStatus.unknown;
      try {
        // Decode to get actual crop size (needed for correct bbox clamp)
        final cropInfo = img.findDecoderForData(latestCrop)?.startDecode(latestCrop);
        final cropW = (cropInfo?.width ?? 320).toDouble();
        final cropH = (cropInfo?.height ?? 320).toDouble();

        final (status, _) = await _helmetDetector.hasNoHelmet(
          frameBytes: latestCrop,
          // Cover the entire crop — HelmetDetector will still apply padTopRatio
          // upward but cy1 is already 0 so it clamps to 0 (whole crop used).
          bbox: [0, 0, cropW, cropH],
          frameWidth: cropW.toInt(),
          frameHeight: cropH.toInt(),
        );
        frameStatus = status;
      } catch (_) {}

      // Sliding window — confirm violation when threshold is met
      final newlyConfirmedNoHelmet = _helmetDetector.updateWindow(tid, frameStatus);
      
      // Keep UI map in sync with detector state
      _helmetStatusMap[tid] = _helmetDetector.getStatus(tid);

      if (newlyConfirmedNoHelmet) {
        final event = ViolationEvent(
          trackId: tid,
          vehicleClass: vehicleClass,
          violationType: 'no_helmet',
          zoneId: state.currentZones.isNotEmpty ? state.currentZones.first : '',
          frameNumber: _frameNum,
          timestampS: _frameNum / 15.0,
          confidence: 0.9,
          headingDeg: state.headingRad != null ? state.headingRad! * 180 / 3.14159 : null,
          bboxPx: state.bbox,
          isCongested: false,
          weather: 'day',
        );
        final key = (tid, 'no_helmet');
        if (!_processedTracks.contains(key)) {
          _processedTracks.add(key);
          _handleViolation(event);
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Violation handler:
  //   1. Immediately save a preliminary record + full-frame snapshot.
  //   2. In the background (async, ~seconds later):
  //      a. Save best vehicle crop from buffer as vehicle image.
  //      b. Run plate YOLO on all vehicle crops → collect plate chips.
  //      c. Run OCR on plate chips → elect best plate.
  //      d. Save best plate chip as plate image.
  //      e. Update the record with plate text + image paths.
  // ─────────────────────────────────────────────────────────────────────────
  Future<void> _handleViolation(ViolationEvent event) async {
    debugPrint('[Violation] ${event.violationType} track=${event.trackId}');
    _showFlash();

    // Preliminary record (no plate yet)
    final record = ViolationRecord.fromEvent(event,
        plateNumber: null, plateConfidence: null, status: ViolationStatus.pending);

    if (mounted) {
      setState(() {
        _totalViolations++;
        _recentViolations.addLast(record);
        if (_recentViolations.length > 3) _recentViolations.removeFirst();
      });
    }

    // Save preliminary record + full-frame snapshot immediately
    await _storage.save(record);
    if (_latestFrame != null) {
      await _storage.saveViolationSnapshot(record, _latestFrame!);
    }

    // ── Background: hand off plate extraction to singleton service ─────────
    final vehicleCrops =
        List<Uint8List>.from(_vehicleBuffers[event.trackId]?.crops ?? []);

    ViolationProcessor.instance.enqueue(record, vehicleCrops, _latestFrame);
  }

  // ─────────────────────────────────────────────────────────────────────────
  void _showFlash() {
    _flashTimer?.cancel();
    if (mounted) {
      setState(() => _flashVisible = true);
      _flashAnim.forward(from: 0);
    }
    _flashTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _flashVisible = false);
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Build
  // ─────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final bool showHud = _calibState == _CalibState.detecting;
    final bool showCalibrationOverlay = _calibState == _CalibState.analysing;
    final bool showConfirmationOverlay = _calibState == _CalibState.confirmingZones;
    final bool showObservingOverlay = _calibState == _CalibState.observing;
    final bool showConfirmingDirectionsOverlay = _calibState == _CalibState.confirmingDirections;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // ── Camera + YOLO inference + Overlays (9:16 AspectRatio Box) ──
        if (_pipelineReady &&
            (_calibState == _CalibState.capturing ||
             _calibState == _CalibState.observing ||
             _calibState == _CalibState.detecting))
          Center(
            child: AspectRatio(
              aspectRatio: 9 / 16,
              child: Stack(
                children: [
                  YOLOView(
                    controller: _yoloController,
                    cameraResolution: '1080p',
                    modelPath: _currentModelPath,
                    task: _currentTask,
                    streamingConfig: YOLOStreamingConfig(
                      maxFPS: 15,
                      includeOriginalImage: true,
                      includeMasks: _includeMasks,
                    ),
                    onModelLoad: (path, task) {
                      debugPrint('[Model] Model loaded successfully: $path');
                      setState(() {
                        _loadedModelPath = path;
                      });
                      final isSegment = task == YOLOTask.segment;
                      _yoloController.setShowOverlays(isSegment);
                      if (!isSegment) {
                        _hideOverlaysCounter = 30; // Force-hide overlays over the next 30 frames
                      }
                    },
                    onStreamingData: _onStreamingData,
                  ),
                  LayoutBuilder(builder: (ctx, constraints) {
                    final sz = constraints.biggest;
                    _scaleX = sz.width  / _frameWidth;
                    _scaleY = sz.height / _frameHeight;
                    return CustomPaint(
                      size: sz,
                      painter: ViolationOverlayPainter(
                        trackStates: Map.from(_pipeline.trackStates),
                        topology: _topology,
                        helmetStatusMap: _helmetStatusMap,
                        recentViolations:
                            _recentViolations.map((r) => r.violationLabel).toList(),
                        scaleX: _scaleX,
                        scaleY: _scaleY,
                        showFlashBorder: _flashVisible,
                        plateBboxes: const [],   // hidden per user request
                        helmetBboxes: const [],  // hidden per user request
                      ),
                    );
                  }),
                ],
              ),
            ),
          )
        else if (_frozenFrame != null && _calibState == _CalibState.analysing)
          Center(
            child: AspectRatio(
              aspectRatio: 9 / 16,
              child: Image.memory(
                _frozenFrame!,
                fit: BoxFit.cover,
              ),
            ),
          ),

        if (!_pipelineReady || (_isModelLoading && (_calibState == _CalibState.idle || _calibState == _CalibState.detecting)))
          Positioned.fill(
            child: _buildModelLoadingOverlay(
              _calibState == _CalibState.detecting
                  ? 'Initializing Camera & AI Tracker…'
                  : 'Initializing Camera & AI Models…',
            ),
          ),

        if (showHud) SafeArea(child: _buildHud()),

        if (_flashVisible && _recentViolations.isNotEmpty && _calibState == _CalibState.detecting)
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: _buildViolationBanner(_recentViolations.last),
          ),

        if (showCalibrationOverlay)
          Positioned.fill(
            child: _buildCalibrationOverlay(),
          ),

        if (_calibState == _CalibState.capturing)
          Positioned.fill(
            child: _buildCapturingOverlay(),
          ),

        if (showConfirmationOverlay)
          Positioned.fill(
            child: _buildConfirmationUI(),
          ),

        if (showObservingOverlay)
          Positioned.fill(
            child: _buildObservingOverlay(),
          ),

        if (showConfirmingDirectionsOverlay)
          Positioned.fill(
            child: _buildConfirmingDirectionsUI(),
          ),
      ]),
    );
  }

  // ── Phase 2 Observing Overlay ─────────────────────────────────────────────
  Widget _buildObservingOverlay() {
    if (_isModelLoading) {
      return _buildModelLoadingOverlay('Loading Camera & AI Vehicle Tracker…');
    }

    final tracksInView = _pipelineReady ? _pipeline.trackStates.length : 0;
    final progress = _observingTotalSeconds > 0
        ? (_observingTotalSeconds - _observingSecondsLeft) / _observingTotalSeconds
        : 0.0;

    return Container(
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Row(
                children: [
                  const Icon(Icons.directions_car_filled_rounded,
                      color: Color(0xFF00D4FF), size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Observing Traffic…',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  // Skip button → go directly to manual heading
                  if (!_isModelLoading)
                    TextButton(
                      onPressed: () {
                        _observingTimer?.cancel();
                        _observingTimer = null;
                        _onObservingTimerExpired();
                      },
                      child: const Text(
                        'Skip',
                        style: TextStyle(
                          color: Color(0xFF00D4FF),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Live camera view (vehicle detections)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: AspectRatio(
                    aspectRatio: 9 / 16,
                    child: Stack(
                      children: [
                        // Live YOLOView (already running behind)
                        const SizedBox.expand(),
                        // Semi-transparent zone overlay
                        if (_phase1Topology != null)
                          LayoutBuilder(builder: (ctx, constraints) {
                            final sz = constraints.biggest;
                            final scaleX = sz.width / _frameWidth;
                            final scaleY = sz.height / _frameHeight;
                            return CustomPaint(
                              size: sz,
                              painter: ConfirmationOverlayPainter(
                                topology: _phase1Topology!,
                                scaleX: scaleX,
                                scaleY: scaleY,
                              ),
                            );
                          }),
                        // If model is loading, show loading overlay inside the aspect ratio box!
                        if (_isModelLoading)
                          Positioned.fill(
                            child: _buildModelLoadingOverlay('Loading Camera & AI Vehicle Tracker…'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Bottom status card
            Padding(
              padding: const EdgeInsets.all(20),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF12121A).withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _isModelLoading
                              ? 'Initializing camera and model...'
                              : '$tracksInView vehicle${tracksInView == 1 ? '' : 's'} in view',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _isModelLoading ? 'Loading…' : '${_observingSecondsLeft}s left',
                          style: const TextStyle(
                            color: Color(0xFF00D4FF),
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: _isModelLoading ? null : progress.clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFF00D4FF)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _isModelLoading
                          ? 'Please wait while the AI tracking model compiles. Keep the camera steady.'
                          : 'Watching live traffic to determine legal direction automatically.\nIf no vehicles are detected, you will be prompted to set direction manually.',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: 11,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmationUI() {
    if (_frozenFrame == null) return const SizedBox.shrink();

    final hasRoad = _detectedTopology?.roadZones.isNotEmpty ?? false;

    return Container(
      color: const Color(0xFF0A0A0E),
      child: SafeArea(
        child: Column(
          children: [
            // Top Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Confirm Detected Zones',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _onRescan,
                        icon: const Icon(Icons.refresh, color: Colors.white60, size: 18),
                        label: const Text('Retry', style: TextStyle(color: Colors.white60)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasRoad
                        ? 'Confirm if the detected road lanes and boundaries are correct.'
                        : 'No road lanes were detected automatically. Please retry or draw manually.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            // Frozen Frame with Custom Paint overlay
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Image.memory(
                              _frozenFrame!,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (ctx, constraints) {
                                final sz = constraints.biggest;
                                final scaleX = sz.width / _frameWidth;
                                final scaleY = sz.height / _frameHeight;
                                return CustomPaint(
                                  size: sz,
                                  painter: ConfirmationOverlayPainter(
                                    topology: _detectedTopology ?? ZoneTopology(zones: []),
                                    scaleX: scaleX,
                                    scaleY: scaleY,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Bottom Actions & Buttons
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (hasRoad) ...[
                    ElevatedButton(
                      onPressed: _onAcceptZones,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF34C759),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Accept & Set Directions',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _onRescan,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.white.withOpacity(0.12)),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            'Re-scan / Retry',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _onManualDraw,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.white.withOpacity(0.12)),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: Text(
                            'Draw Manually',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmingDirectionsUI() {
    if (_frozenFrame == null || _detectedTopology == null) return const SizedBox.shrink();

    return Container(
      color: const Color(0xFF0A0A0E),
      child: SafeArea(
        child: Column(
          children: [
            // Top Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Confirm Auto-Detected Directions',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Review the legal traffic direction arrows automatically detected for each lane.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),

            // Frozen Frame with Custom Paint overlay
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Image.memory(
                              _frozenFrame!,
                              fit: BoxFit.cover,
                            ),
                          ),
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (ctx, constraints) {
                                final sz = constraints.biggest;
                                final scaleX = sz.width / _frameWidth;
                                final scaleY = sz.height / _frameHeight;
                                return CustomPaint(
                                  size: sz,
                                  painter: ConfirmationOverlayPainter(
                                    topology: _detectedTopology!,
                                    scaleX: scaleX,
                                    scaleY: scaleY,
                                    drawDirections: true,
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Bottom Actions & Buttons
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      if (_detectedTopology != null) {
                        _finishCalibration(_detectedTopology!);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF34C759),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Accept & Start Detection',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () {
                      // Retry / Rescan Phase 2
                      _startObservingPhase();
                    },
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      'Retry Auto-Detection',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Auto-Calibration Overlay HUD ─────────────────────────────────────────
  Widget _buildCalibrationOverlay() {
    final title = _calibState == _CalibState.capturing
        ? 'Scanning Scene…'
        : 'Processing Road Layout…';
    final subtitle = _calibState == _CalibState.capturing
        ? 'Waiting for a clear camera frame to analyze. Keep camera static.'
        : 'Running road segmentation and boundary mapping using AI...';

    return Container(
      color: Colors.black.withOpacity(0.6),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 36),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF12121A).withOpacity(0.92),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFF00D4FF)),
              const SizedBox(height: 24),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModelLoadingOverlay(String message) {
    return Container(
      color: const Color(0xFF0A0A0E),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF00D4FF)),
            const SizedBox(height: 20),
            Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Please wait a moment...',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Phase 1 Capturing Overlay ─────────────────────────────────────────────
  Widget _buildCapturingOverlay() {
    if (_isModelLoading) {
      return _buildModelLoadingOverlay('Loading Camera & AI Road Model…');
    }
    return Container(
      color: Colors.transparent,
      child: SafeArea(
        child: Column(
          children: [
            // Top Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              color: Colors.black.withValues(alpha: 0.55),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.center_focus_strong_outlined,
                          color: Color(0xFF00D4FF), size: 22),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Scan & Align Road Lanes',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white60),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Position camera to view road lanes clearly. Colored masks show real-time AI segmentation.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),

            // Live feed in middle is transparent
            const Expanded(child: SizedBox.shrink()),

            // Bottom Actions Card
            Padding(
              padding: const EdgeInsets.all(20),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF12121A).withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _onCapturePressed,
                      icon: const Icon(Icons.camera_alt_rounded, size: 20),
                      label: const Text(
                        'Capture Layout',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00D4FF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _onManualDraw,
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Draw Manually',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── HUD ──────────────────────────────────────────────────────────────────
  Widget _buildHud() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        _HudButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: () => Navigator.pop(context)),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.6),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.track_changes_rounded,
                color: Color(0xFF00D4FF), size: 14),
            const SizedBox(width: 6),
            Text(
              'Frame $_frameNum  │  '
              '${_pipelineReady ? _pipeline.trackStates.length : 0} tracks',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500),
            ),
          ]),
        ),
        const Spacer(),
        if (_totalViolations > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFFFF3B30).withOpacity(0.95),
              borderRadius: BorderRadius.circular(30),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.warning_rounded, color: Colors.white, size: 14),
              const SizedBox(width: 5),
              Text('$_totalViolations violations',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
      ]),
    );
  }

  // ── Violation banner ─────────────────────────────────────────────────────
  Widget _buildViolationBanner(ViolationRecord record) {
    final color = record.violationType == 'wrong_side'
        ? const Color(0xFFFF3B30)
        : record.violationType == 'footpath_driving'
            ? const Color(0xFFFF9500)
            : const Color(0xFF34C759);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [color.withOpacity(0.0), color.withOpacity(0.95)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 36),
      child: SafeArea(
        top: false,
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.warning_rounded,
                color: Colors.white, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('⚠  ${record.violationLabel.toUpperCase()}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5)),
                const SizedBox(height: 3),
                Text(
                  'Track #${record.trackId}  ·  ${record.vehicleClass}'
                  '${record.plateNumber != null ? '  ·  🔢 ${record.plateNumber}' : ''}',
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.85), fontSize: 12),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DetectionBox — used by ViolationOverlayPainter
// ─────────────────────────────────────────────────────────────────────────────
class DetectionBox {
  const DetectionBox({
    required this.rect,
    required this.label,
    required this.confidence,
    required this.color,
  });
  final Rect rect;
  final String label;
  final double confidence;
  final Color color;
}

// ─────────────────────────────────────────────────────────────────────────────
class _HudButton extends StatelessWidget {
  const _HudButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    );
  }
}

class ConfirmationOverlayPainter extends CustomPainter {
  ConfirmationOverlayPainter({
    required this.topology,
    required this.scaleX,
    required this.scaleY,
    this.drawDirections = false,
  });

  final ZoneTopology topology;
  final double scaleX;
  final double scaleY;
  final bool drawDirections;

  Color _getColorForType(ZoneType type) {
    switch (type) {
      case ZoneType.road:
        return const Color(0xFF00D4FF);
      case ZoneType.footpath:
        return const Color(0xFF34C759);
      case ZoneType.divider:
        return const Color(0xFFFF3B30);
      case ZoneType.sideland:
        return const Color(0xFFAF52DE);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final zone in topology.zones) {
      if (zone.polygon.isEmpty) continue;
      final zoneColor = _getColorForType(zone.zoneType);

      final fillPaint = Paint()
        ..color = zoneColor.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill;

      final borderPaint = Paint()
        ..color = zoneColor
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;

      final path = Path();
      path.moveTo(zone.polygon[0].dx * scaleX, zone.polygon[0].dy * scaleY);
      for (int i = 1; i < zone.polygon.length; i++) {
        path.lineTo(zone.polygon[i].dx * scaleX, zone.polygon[i].dy * scaleY);
      }
      path.close();

      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, borderPaint);

      // Draw text label near the first point
      final textSpan = TextSpan(
        text: zone.zoneType.name.toUpperCase(),
        style: TextStyle(
          color: zoneColor,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black.withValues(alpha: 0.6),
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(zone.polygon[0].dx * scaleX, zone.polygon[0].dy * scaleY - 12),
      );

      // Draw legal direction arrow if requested and heading is set
      if (drawDirections && zone.zoneType == ZoneType.road && zone.legalHeadingDeg != 0.0) {
        final sPts = zone.polygon.map((p) => Offset(p.dx * scaleX, p.dy * scaleY)).toList();
        if (sPts.length >= 3) {
          final cx = sPts.map((p) => p.dx).reduce((a, b) => a + b) / sPts.length;
          final cy = sPts.map((p) => p.dy).reduce((a, b) => a + b) / sPts.length;

          final rad = zone.legalHeadingDeg * math.pi / 180;
          final tail = Offset(cx - 20 * math.cos(rad), cy - 20 * math.sin(rad));
          final tip = Offset(cx + 20 * math.cos(rad), cy + 20 * math.sin(rad));

          _drawArrow(canvas, tail, tip);
        }
      }
    }
  }

  void _drawArrow(Canvas canvas, Offset tail, Offset tip) {
    const color = Color(0xFFFFC800);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(tail, tip, paint);

    // Arrowhead
    const headLen = 12.0;
    const headAngle = 0.45;
    final angle = math.atan2(tip.dy - tail.dy, tip.dx - tail.dx);
    final p1 = Offset(
        tip.dx - headLen * math.cos(angle - headAngle),
        tip.dy - headLen * math.sin(angle - headAngle));
    final p2 = Offset(
        tip.dx - headLen * math.cos(angle + headAngle),
        tip.dy - headLen * math.sin(angle + headAngle));
    final head = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(head, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant ConfirmationOverlayPainter oldDelegate) {
    return oldDelegate.topology != topology ||
        oldDelegate.scaleX != scaleX ||
        oldDelegate.scaleY != scaleY ||
        oldDelegate.drawDirections != drawDirections;
  }
}
