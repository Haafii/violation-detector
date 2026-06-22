import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/violation_record.dart';

/// Persists violation records, snapshots (JPEG + JSON sidecar) and zone topology
/// to phone local storage.
///
/// Violation snapshots are saved to:
///   <externalStorage>/ViolationDetector/violations/
/// in the same schema as the Python event_logger:
///   violation_<eventId>.jpg   — frame JPEG
///   violation_<eventId>.json  — full event metadata
///
/// Falls back to getApplicationDocumentsDirectory() on devices without
/// external storage (emulators, etc.).
class ViolationStorageService {
  static const _listFileName = 'violations.json';

  // ── Storage root ─────────────────────────────────────────────────────────

  /// External downloads-like dir, visible to file managers.
  /// Falls back to app-documents if unavailable.
  Future<Directory> get _violationsDir async {
    Directory? base;
    try {
      final dirs = await getExternalStorageDirectories();
      if (dirs != null && dirs.isNotEmpty) {
        base = dirs.first;
      }
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();

    final vDir = Directory('${base.path}/ViolationDetector/violations');
    if (!vDir.existsSync()) await vDir.create(recursive: true);
    return vDir;
  }

  Future<File> get _listFile async {
    final dir = await _violationsDir;
    return File('${dir.path}/$_listFileName');
  }

  // ── List persistence ──────────────────────────────────────────────────────

  /// Load all saved violation records (newest first).
  Future<List<ViolationRecord>> loadAll() async {
    try {
      final f = await _listFile;
      if (!f.existsSync()) return [];
      final raw = await f.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => ViolationRecord.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (e) {
      debugPrint('[Storage] Load error: $e');
      return [];
    }
  }

  /// Append / update a violation record in the list file.
  Future<void> save(ViolationRecord record) async {
    try {
      final existing = await loadAll();
      final idx = existing.indexWhere((r) => r.eventId == record.eventId);
      if (idx >= 0) {
        existing[idx] = record;
      } else {
        existing.insert(0, record);
      }
      final f = await _listFile;
      await f.writeAsString(
          jsonEncode(existing.map((r) => r.toJson()).toList()));
    } catch (e) {
      debugPrint('[Storage] Save error: $e');
    }
  }

  // ── Snapshot save (JPEG + JSON sidecar) ───────────────────────────────────

  /// Save [frameJpeg] as `violation_<eventId>.jpg` and a JSON sidecar with
  /// all violation metadata (matching the Python event_logger schema).
  ///
  /// Returns the path to the saved JPEG, or null on error.
  Future<String?> saveViolationSnapshot(
      ViolationRecord record, Uint8List frameJpeg, {List<Uint8List>? plateChips}) async {
    try {
      final dir = await _violationsDir;
      final safeId = record.eventId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

      // JPEG
      final jpegFile = File('${dir.path}/violation_$safeId.jpg');
      await jpegFile.writeAsBytes(frameJpeg);
      
      // Save plate chips if provided
      final chipPaths = <String>[];
      if (plateChips != null && plateChips.isNotEmpty) {
        for (var i = 0; i < plateChips.length; i++) {
           final chipFile = File('${dir.path}/violation_${safeId}_plate_$i.jpg');
           await chipFile.writeAsBytes(plateChips[i]);
           chipPaths.add(chipFile.path);
        }
      }

      // JSON sidecar — mirrors Python event_logger CSV_FIELDS
      final meta = {
        'event_id':          record.eventId,
        'timestamp_str':     record.timestamp.toIso8601String(),
        'frame_number':      record.frameNumber,
        'track_id':          record.trackId,
        'vehicle_class':     record.vehicleClass,
        'violation_type':    record.violationType,
        'zone_id':           record.zoneId ?? '',
        'heading_deg':       record.headingDeg ?? 0.0,
        'legal_heading_deg': record.legalHeadingDeg ?? 0.0,
        'candidate_frames':  record.candidateFrames ?? 0,
        'confidence':        record.confidence ?? 0.0,
        'plate_number':      record.plateNumber ?? '',
        'bbox':              record.bbox ?? [],
        'image_path':        jpegFile.path,
      };
      if (chipPaths.isNotEmpty) {
         meta['plate_crops'] = chipPaths;
      }
      
      final jsonFile = File('${dir.path}/violation_$safeId.json');
      await jsonFile.writeAsString(const JsonEncoder.withIndent('  ').convert(meta));

      debugPrint('[Storage] Snapshot saved → ${jpegFile.path}');
      return jpegFile.path;
    } catch (e) {
      debugPrint('[Storage] Snapshot save error: $e');
      return null;
    }
  }

  // ── Topology ──────────────────────────────────────────────────────────────

  Future<Directory> get _topologiesDir async {
    final dir = await _violationsDir;
    final tDir = Directory('${dir.path}/../topologies');
    if (!tDir.existsSync()) await tDir.create(recursive: true);
    return tDir;
  }

  /// Save zone topology JSON with metadata and set as the active one.
  Future<void> saveTopology(Map<String, dynamic> json) async {
    try {
      final dir = await _violationsDir;
      // 1. Save as the active one (main topology.json)
      final activeFile = File('${dir.path}/../topology.json');
      await activeFile.parent.create(recursive: true);

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dateStr = _formatDateTime(DateTime.now());

      final topologyId = 'topology_$timestamp';
      final enrichedJson = {
        'id': topologyId,
        'name': 'Calibration - $dateStr',
        'timestamp': timestamp,
        'zones': json['zones'],
      };

      final enrichedStr = jsonEncode(enrichedJson);
      await activeFile.writeAsString(enrichedStr);

      // 2. Save inside the topologies folder for historical list
      final tDir = await _topologiesDir;
      final f = File('${tDir.path}/$topologyId.json');
      await f.writeAsString(enrichedStr);

      debugPrint('[Storage] Topology saved successfully: $topologyId');
    } catch (e) {
      debugPrint('[Storage] Topology save error: $e');
    }
  }

  String _formatDateTime(DateTime dt) {
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]}, $hour:$minute $ampm';
  }

  /// Load active zone topology JSON, returns null if not saved yet.
  Future<Map<String, dynamic>?> loadTopology() async {
    try {
      final dir = await _violationsDir;
      final f = File('${dir.path}/../topology.json');
      if (!f.existsSync()) return null;
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      return null;
    }
  }

  /// Get list of all saved calibrations
  Future<List<Map<String, dynamic>>> getSavedTopologies() async {
    try {
      final tDir = await _topologiesDir;
      if (!tDir.existsSync()) return [];
      final List<Map<String, dynamic>> list = [];
      final files = tDir.listSync();
      for (final entity in files) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final content = await entity.readAsString();
            final map = jsonDecode(content) as Map<String, dynamic>;
            list.add(map);
          } catch (_) {}
        }
      }
      // Sort by timestamp desc (newest first)
      list.sort((a, b) {
        final tA = a['timestamp'] as int? ?? 0;
        final tB = b['timestamp'] as int? ?? 0;
        return tB.compareTo(tA);
      });
      return list;
    } catch (e) {
      debugPrint('[Storage] Error listing topologies: $e');
      return [];
    }
  }

  /// Make a specific saved topology active
  Future<void> makeTopologyActive(String id) async {
    try {
      final tDir = await _topologiesDir;
      final sourceFile = File('${tDir.path}/$id.json');
      if (!sourceFile.existsSync()) return;

      final dir = await _violationsDir;
      final activeFile = File('${dir.path}/../topology.json');
      await activeFile.writeAsString(await sourceFile.readAsString());
      debugPrint('[Storage] Topology $id is now active.');
    } catch (e) {
      debugPrint('[Storage] Error making topology active: $e');
    }
  }

  /// Delete a specific calibration
  Future<void> deleteTopology(String id) async {
    try {
      final tDir = await _topologiesDir;
      final f = File('${tDir.path}/$id.json');
      if (f.existsSync()) await f.delete();

      // If this was the active one, delete topology.json or set another one as active
      final dir = await _violationsDir;
      final activeFile = File('${dir.path}/../topology.json');
      if (activeFile.existsSync()) {
        final activeContent = await activeFile.readAsString();
        final activeMap = jsonDecode(activeContent) as Map<String, dynamic>;
        if (activeMap['id'] == id) {
          await activeFile.delete();
          // Try to make the next newest one active
          final list = await getSavedTopologies();
          if (list.isNotEmpty) {
            await makeTopologyActive(list.first['id'] as String);
          }
        }
      }
    } catch (e) {
      debugPrint('[Storage] Error deleting topology: $e');
    }
  }

  /// Delete all saved calibrations
  Future<void> deleteAllTopologies() async {
    try {
      final tDir = await _topologiesDir;
      if (tDir.existsSync()) {
        await tDir.delete(recursive: true);
      }
      final dir = await _violationsDir;
      final activeFile = File('${dir.path}/../topology.json');
      if (activeFile.existsSync()) {
        await activeFile.delete();
      }
      debugPrint('[Storage] All topologies deleted.');
    } catch (e) {
      debugPrint('[Storage] Error deleting all topologies: $e');
    }
  }

  // ── Vehicle / plate image helpers ─────────────────────────────────────────

  /// Save the best vehicle crop JPEG for [record].
  /// Returns the saved file path, or null on error.
  Future<String?> saveVehicleImage(
      ViolationRecord record, Uint8List vehicleJpeg) async {
    try {
      final dir = await _violationsDir;
      final safeId =
          record.eventId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final f = File('${dir.path}/violation_${safeId}_vehicle.jpg');
      await f.writeAsBytes(vehicleJpeg);
      debugPrint('[Storage] Vehicle image saved → ${f.path}');
      return f.path;
    } catch (e) {
      debugPrint('[Storage] Vehicle image save error: $e');
      return null;
    }
  }

  /// Save the best plate chip JPEG for [record].
  /// Returns the saved file path, or null on error.
  Future<String?> savePlateImage(
      ViolationRecord record, Uint8List plateJpeg) async {
    try {
      final dir = await _violationsDir;
      final safeId =
          record.eventId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      final f = File('${dir.path}/violation_${safeId}_plate.jpg');
      await f.writeAsBytes(plateJpeg);
      debugPrint('[Storage] Plate image saved → ${f.path}');
      return f.path;
    } catch (e) {
      debugPrint('[Storage] Plate image save error: $e');
      return null;
    }
  }

  // ── Legacy snapshot helper (kept for compatibility) ─────────────────────

  Future<String?> saveSnapshot(Uint8List bytes, String filename) async {
    try {
      final dir = await _violationsDir;
      final f = File('${dir.path}/$filename');
      await f.writeAsBytes(bytes);
      return f.path;
    } catch (e) {
      debugPrint('[Storage] Snapshot save error: $e');
      return null;
    }
  }

  /// Delete all records (for reset).
  Future<void> clearAll() async {
    try {
      final f = await _listFile;
      if (f.existsSync()) await f.delete();
    } catch (e) {
      debugPrint('[Storage] Clear error: $e');
    }
  }
}
