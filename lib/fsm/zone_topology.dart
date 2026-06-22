import 'dart:ui' show Offset;

import 'fsm_state.dart';
import 'geometry.dart';

/// A road zone definition.
class Zone {
  const Zone({
    required this.zoneId,
    required this.zoneType,
    required this.polygon, // pixel-space vertices
    this.legalHeadingDeg = 0.0,
    this.headingToleranceDeg = 30.0,
    this.vehicleClasses = const ['all'],
    this.needsManualHeading = false,
  });

  final String zoneId;
  final ZoneType zoneType;
  final List<Offset> polygon;
  final double legalHeadingDeg;
  final double headingToleranceDeg;
  final List<String> vehicleClasses;
  final bool needsManualHeading;

  /// Serialise to JSON-compatible map.
  Map<String, dynamic> toJson() => {
        'zone_id': zoneId,
        'zone_type': zoneType.name,
        'polygon_px': polygon.map((p) => [p.dx, p.dy]).toList(),
        'legal_heading_deg': legalHeadingDeg,
        'heading_tolerance_deg': headingToleranceDeg,
        'vehicle_classes': vehicleClasses,
        'needs_manual_heading': needsManualHeading,
      };

  /// Deserialise from JSON.
  factory Zone.fromJson(Map<String, dynamic> json) {
    final polyRaw = json['polygon_px'] as List<dynamic>;
    final polygon = polyRaw
        .map((p) => Offset(
              (p as List<dynamic>)[0].toDouble(),
              p[1].toDouble(),
            ))
        .toList();
    final ztStr = (json['zone_type'] as String?) ?? 'road';
    final zt = ZoneType.values.firstWhere(
      (e) => e.name == ztStr,
      orElse: () => ZoneType.road,
    );
    return Zone(
      zoneId: json['zone_id'] as String,
      zoneType: zt,
      polygon: polygon,
      legalHeadingDeg: (json['legal_heading_deg'] as num?)?.toDouble() ?? 0.0,
      headingToleranceDeg:
          (json['heading_tolerance_deg'] as num?)?.toDouble() ?? 30.0,
      vehicleClasses: (json['vehicle_classes'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          ['all'],
      needsManualHeading: json['needs_manual_heading'] as bool? ?? false,
    );
  }
}

/// Road topology: collection of zones for one camera angle.
class ZoneTopology {
  ZoneTopology({required this.zones});

  final List<Zone> zones;

  List<Zone> get roadZones =>
      zones.where((z) => z.zoneType == ZoneType.road).toList();
  List<Zone> get footpathZones =>
      zones.where((z) => z.zoneType == ZoneType.footpath).toList();
  List<Zone> get sidelandZones =>
      zones.where((z) => z.zoneType == ZoneType.sideland).toList();

  /// All zones whose polygon contains [pt].
  List<Zone> getZonesForPoint(Offset pt) =>
      zones.where((z) => pointInPolygon(pt, z.polygon)).toList();

  /// Returns true if [pt] is inside any footpath zone.
  bool isInFootpathZone(Offset pt) =>
      footpathZones.any((z) => pointInPolygon(pt, z.polygon));

  /// Returns true if [pt] is inside any sideland zone.
  bool isInSidelandZone(Offset pt) =>
      sidelandZones.any((z) => pointInPolygon(pt, z.polygon));

  /// Serialise to JSON (for persistence).
  Map<String, dynamic> toJson() => {
        'zones': zones.map((z) => z.toJson()).toList(),
      };

  /// Deserialise from JSON.
  factory ZoneTopology.fromJson(Map<String, dynamic> json) {
    final zonesRaw = json['zones'] as List<dynamic>? ?? [];
    return ZoneTopology(
      zones: zonesRaw
          .map((z) => Zone.fromJson(z as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Create a fallback 2-zone topology for a frame of given dimensions.
  factory ZoneTopology.fallback(double frameW, double frameH) {
    final mid = frameW / 2;
    return ZoneTopology(zones: [
      Zone(
        zoneId: 'left_lane',
        zoneType: ZoneType.road,
        polygon: [
          Offset(0, 0),
          Offset(mid, 0),
          Offset(mid, frameH),
          Offset(0, frameH),
        ],
        legalHeadingDeg: 270,
        headingToleranceDeg: 30,
      ),
      Zone(
        zoneId: 'right_lane',
        zoneType: ZoneType.road,
        polygon: [
          Offset(mid, 0),
          Offset(frameW, 0),
          Offset(frameW, frameH),
          Offset(mid, frameH),
        ],
        legalHeadingDeg: 90,
        headingToleranceDeg: 30,
      ),
    ]);
  }
}
