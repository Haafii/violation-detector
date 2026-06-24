import 'dart:convert';

import '../fsm/fsm_state.dart';

enum ViolationStatus { pending, processing, complete }

/// Mirrors the Python ViolationRecord JSON schema.
class ViolationRecord {
  ViolationRecord({
    String? eventId,
    required this.trackId,
    required this.violationType,
    required this.vehicleClass,
    required this.zoneId,
    this.plateNumber,
    this.plateConfidence,
    required this.violationConfidence,
    this.headingDeg,
    this.legalHeadingDeg,
    this.candidateFrames,
    this.confidence,
    this.bbox,
    required this.timestamp,
    required this.timestampStr,
    required this.frameNumber,
    required this.weather,
    required this.isCongested,
    this.snapshotPath,
    this.vehicleImagePath,
    this.plateImagePath,
    this.helmetImagePath,
    this.status = ViolationStatus.pending,
  }) : eventId = eventId ??
           '${trackId}_${violationType}_${DateTime.now().millisecondsSinceEpoch}';

  final String eventId;
  final int trackId;
  final String violationType;
  final String vehicleClass;
  final String zoneId;
  final String? plateNumber;
  final double? plateConfidence;
  final double violationConfidence;
  final double? headingDeg;
  final double? legalHeadingDeg;
  final int? candidateFrames;
  final double? confidence;
  final List<double>? bbox;
  final DateTime timestamp;
  final String timestampStr;
  final int frameNumber;
  final String weather;
  final bool isCongested;
  String? snapshotPath;
  String? vehicleImagePath;   // saved vehicle crop JPEG path
  String? plateImagePath;     // saved plate chip JPEG path
  String? helmetImagePath;    // saved helmet crop JPEG path
  final ViolationStatus status;

  /// Human-readable violation type label.
  String get violationLabel {
    switch (violationType) {
      case kViolationWrongSide:
        return 'Wrong Side';
      case kViolationFootpath:
        return 'Footpath Driving';
      case kViolationNoHelmet:
        return 'No Helmet';
      default:
        return violationType.replaceAll('_', ' ').toUpperCase();
    }
  }

  factory ViolationRecord.fromEvent(
    ViolationEvent event, {
    String? plateNumber,
    double? plateConfidence,
    String? snapshotPath,
    ViolationStatus status = ViolationStatus.pending,
  }) {
    return ViolationRecord(
      trackId: event.trackId,
      violationType: event.violationType,
      vehicleClass: event.vehicleClass,
      zoneId: event.zoneId,
      plateNumber: plateNumber,
      plateConfidence: plateConfidence,
      violationConfidence: event.confidence,
      headingDeg: event.headingDeg,
      legalHeadingDeg: event.legalHeadingDeg,
      candidateFrames: event.candidateFrames,
      confidence: event.confidence,
      bbox: event.bbox,
      timestamp: DateTime.now(),
      timestampStr: event.timestampStr,
      frameNumber: event.frameNumber,
      weather: event.weather,
      isCongested: event.isCongested,
      snapshotPath: snapshotPath,
      status: status,
    );
  }

  ViolationRecord copyWith({
    String? plateNumber,
    double? plateConfidence,
    String? snapshotPath,
    List<double>? bbox,
    String? vehicleImagePath,
    String? plateImagePath,
    String? helmetImagePath,
    ViolationStatus? status,
  }) {
    return ViolationRecord(
      eventId: eventId,
      trackId: trackId,
      violationType: violationType,
      vehicleClass: vehicleClass,
      zoneId: zoneId,
      plateNumber: plateNumber ?? this.plateNumber,
      plateConfidence: plateConfidence ?? this.plateConfidence,
      violationConfidence: violationConfidence,
      headingDeg: headingDeg,
      legalHeadingDeg: legalHeadingDeg,
      candidateFrames: candidateFrames,
      confidence: confidence,
      bbox: bbox ?? this.bbox,
      timestamp: timestamp,
      timestampStr: timestampStr,
      frameNumber: frameNumber,
      weather: weather,
      isCongested: isCongested,
      snapshotPath: snapshotPath ?? this.snapshotPath,
      vehicleImagePath: vehicleImagePath ?? this.vehicleImagePath,
      plateImagePath: plateImagePath ?? this.plateImagePath,
      helmetImagePath: helmetImagePath ?? this.helmetImagePath,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toJson() => {
        'event_id': eventId,
        'track_id': trackId,
        'violation_type': violationType,
        'vehicle_class': vehicleClass,
        'zone_id': zoneId,
        'plate_number': plateNumber,
        'plate_confidence':
            plateConfidence != null ? double.parse(plateConfidence!.toStringAsFixed(3)) : null,
        'violation_confidence': double.parse(violationConfidence.toStringAsFixed(3)),
        'heading_deg': headingDeg,
        'legal_heading_deg': legalHeadingDeg,
        'candidate_frames': candidateFrames,
        'confidence': confidence,
        'bbox': bbox,
        'timestamp': timestamp.toIso8601String(),
        'timestamp_str': timestampStr,
        'frame_number': frameNumber,
        'weather': weather,
        'is_congested': isCongested,
        'snapshot_path': snapshotPath,
        'vehicle_image_path': vehicleImagePath,
        'plate_image_path': plateImagePath,
        'helmet_image_path': helmetImagePath,
        'status': status.name,
      };

  factory ViolationRecord.fromJson(Map<String, dynamic> json) {
    ViolationStatus statusVal = ViolationStatus.complete;
    if (json['status'] != null) {
      try {
        statusVal = ViolationStatus.values.byName(json['status'] as String);
      } catch (_) {
        statusVal = ViolationStatus.complete;
      }
    }
    return ViolationRecord(
      eventId: json['event_id'] as String?,
      trackId: json['track_id'] as int,
      violationType: json['violation_type'] as String,
      vehicleClass: (json['vehicle_class'] as String?) ?? 'unknown',
      zoneId: (json['zone_id'] as String?) ?? '',
      plateNumber: json['plate_number'] as String?,
      plateConfidence: (json['plate_confidence'] as num?)?.toDouble(),
      violationConfidence:
          (json['violation_confidence'] as num?)?.toDouble() ?? 0.0,
      headingDeg: (json['heading_deg'] as num?)?.toDouble(),
      legalHeadingDeg: (json['legal_heading_deg'] as num?)?.toDouble(),
      candidateFrames: json['candidate_frames'] as int?,
      confidence: (json['confidence'] as num?)?.toDouble(),
      bbox: (json['bbox'] as List<dynamic>?)
          ?.map((e) => (e as num).toDouble()).toList(),
      timestamp: DateTime.parse(json['timestamp'] as String),
      timestampStr: (json['timestamp_str'] as String?) ?? '',
      frameNumber: (json['frame_number'] as int?) ?? 0,
      weather: (json['weather'] as String?) ?? 'day',
      isCongested: (json['is_congested'] as bool?) ?? false,
      snapshotPath: json['snapshot_path'] as String?,
      vehicleImagePath: json['vehicle_image_path'] as String?,
      plateImagePath: json['plate_image_path'] as String?,
      helmetImagePath: json['helmet_image_path'] as String?,
      status: statusVal,
    );
  }

  String toJsonString() => jsonEncode(toJson());
}

