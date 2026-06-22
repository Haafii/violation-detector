import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/violation_storage_service.dart';

class HomeScreen extends StatelessWidget {
  HomeScreen({super.key});

  final _storage = ViolationStorageService();

  void _handleStartDetection(BuildContext context) async {
    final stored = await _storage.loadTopology();
    final prefs = await SharedPreferences.getInstance();
    final method = prefs.getString('calibration_method') ?? 'automated';
    final duration = prefs.getInt('calibration_duration_seconds') ?? 20;

    if (!context.mounted) return;

    if (stored != null) {
      final isAuto = method == 'automated';
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C2A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Text('Start Detection',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          content: Text(
              isAuto
                  ? 'An active zone calibration exists. Would you like to use the existing calibration or start a new $duration-second auto-calibration?'
                  : 'An active zone calibration exists. Would you like to use the existing calibration or start a new manual calibration?',
              style: const TextStyle(color: Colors.white60, height: 1.4)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.white38)),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                if (isAuto) {
                  Navigator.pushNamed(context, '/detect', arguments: {'forceCalibrate': true});
                } else {
                  Navigator.pushNamed(context, '/calibrate');
                }
              },
              child: const Text('Start New', style: TextStyle(color: Color(0xFF00D4FF), fontWeight: FontWeight.bold)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.pushNamed(context, '/detect', arguments: {'useSaved': true});
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF34C759),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Use Active'),
            ),
          ],
        ),
      );
    } else {
      if (method == 'automated') {
        Navigator.pushNamed(context, '/detect', arguments: {'forceCalibrate': true});
      } else {
        Navigator.pushNamed(context, '/calibrate');
      }
    }
  }

  Widget _buildMethodChip(
    BuildContext context, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00D4FF).withOpacity(0.12)
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? const Color(0xFF00D4FF)
                : Colors.white.withOpacity(0.08),
            width: 1.5,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? const Color(0xFF00D4FF) : Colors.white60,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  void _showSettingsSheet(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    String currentMethod = prefs.getString('calibration_method') ?? 'automated';
    int currentDuration = (prefs.getInt('calibration_duration_seconds') ?? 20).clamp(20, 60);

    double vehicleTrack = prefs.getDouble('vehicle_track_threshold') ?? 0.40;
    double vehicleHigh = prefs.getDouble('vehicle_high_threshold') ?? 0.50;
    double helmetConf = prefs.getDouble('helmet_conf_threshold') ?? 0.35;
    double plateConf = prefs.getDouble('plate_conf_threshold') ?? 0.30;
    double roadConf = prefs.getDouble('road_conf_threshold') ?? 0.25;

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF12121A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Widget buildThresholdSlider({
            required String label,
            required double value,
            required ValueChanged<double> onChanged,
          }) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      value.toStringAsFixed(2),
                      style: const TextStyle(
                        color: Color(0xFF00D4FF),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Slider(
                  value: value,
                  min: 0.1,
                  max: 0.9,
                  divisions: 16, // steps of 0.05
                  onChanged: onChanged,
                ),
                const SizedBox(height: 10),
              ],
            );
          }

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 28,
              bottom: 28 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Settings',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Configure calibration and detection properties.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.5),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Calibration Method',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _buildMethodChip(
                          ctx,
                          label: 'Manual',
                          selected: currentMethod == 'manual',
                          onTap: () {
                            setS(() {
                              currentMethod = 'manual';
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildMethodChip(
                          ctx,
                          label: 'Automated',
                          selected: currentMethod == 'automated',
                          onTap: () {
                            setS(() {
                              currentMethod = 'automated';
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  if (currentMethod == 'automated') ...[
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Calibration Duration',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '$currentDuration seconds',
                          style: const TextStyle(
                            color: Color(0xFF00D4FF),
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SliderTheme(
                      data: SliderTheme.of(ctx).copyWith(
                        activeTrackColor: const Color(0xFF00D4FF),
                        inactiveTrackColor: Colors.white.withOpacity(0.1),
                        thumbColor: const Color(0xFF00D4FF),
                        overlayColor: const Color(0xFF00D4FF).withOpacity(0.2),
                        valueIndicatorColor: const Color(0xFF00D4FF),
                      ),
                      child: Slider(
                        value: currentDuration.toDouble(),
                        min: 20.0,
                        max: 60.0,
                        divisions: 8,
                        onChanged: (val) {
                          setS(() {
                            currentDuration = val.round();
                          });
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 12),
                  const Text(
                    'Model Confidence Thresholds',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: const Color(0xFF00D4FF),
                      inactiveTrackColor: Colors.white.withOpacity(0.1),
                      thumbColor: const Color(0xFF00D4FF),
                      overlayColor: const Color(0xFF00D4FF).withOpacity(0.2),
                      valueIndicatorColor: const Color(0xFF00D4FF),
                    ),
                    child: Column(
                      children: [
                        buildThresholdSlider(
                          label: 'Vehicle Track Init (highThresh)',
                          value: vehicleHigh,
                          onChanged: (val) {
                            setS(() {
                              vehicleHigh = val;
                              if (vehicleHigh < vehicleTrack) {
                                vehicleTrack = vehicleHigh;
                              }
                            });
                          },
                        ),
                        buildThresholdSlider(
                          label: 'Vehicle Detection (trackThresh)',
                          value: vehicleTrack,
                          onChanged: (val) {
                            setS(() {
                              vehicleTrack = val;
                              if (vehicleTrack > vehicleHigh) {
                                vehicleHigh = vehicleTrack;
                              }
                            });
                          },
                        ),
                        buildThresholdSlider(
                          label: 'Helmet Detection Confidence',
                          value: helmetConf,
                          onChanged: (val) {
                            setS(() {
                              helmetConf = val;
                            });
                          },
                        ),
                        buildThresholdSlider(
                          label: 'Plate Detection Confidence',
                          value: plateConf,
                          onChanged: (val) {
                            setS(() {
                              plateConf = val;
                            });
                          },
                        ),
                        buildThresholdSlider(
                          label: 'Road Segmentation Confidence',
                          value: roadConf,
                          onChanged: (val) {
                            setS(() {
                              roadConf = val;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () async {
                        await prefs.setString('calibration_method', currentMethod);
                        await prefs.setInt('calibration_duration_seconds', currentDuration);
                        await prefs.setDouble('vehicle_track_threshold', vehicleTrack);
                        await prefs.setDouble('vehicle_high_threshold', vehicleHigh);
                        await prefs.setDouble('helmet_conf_threshold', helmetConf);
                        await prefs.setDouble('plate_conf_threshold', plateConf);
                        await prefs.setDouble('road_conf_threshold', roadConf);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00D4FF),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: const Text(
                        'Save Settings',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Stack(
          children: [
            // Animated background gradient orbs
            _BackgroundOrbs(),
            // Main content
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 56),
                  // Badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00D4FF).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: const Color(0xFF00D4FF).withOpacity(0.3)),
                    ),
                    child: const Text(
                      '🚨  TRAFFIC AI  v1.0',
                      style: TextStyle(
                        color: Color(0xFF00D4FF),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Title
                  const Text(
                    'Violation\nDetector',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 48,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'YOLOv11n · ByteTrack · ML Kit OCR\nReal-time traffic violation detection',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 14,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 44),
                  // Capability chips
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _CapChip('Wrong-Side', '↔', const Color(0xFFFF3B30)),
                      _CapChip('Footpath', '🛤', const Color(0xFFFF9500)),
                      _CapChip('No Helmet', '⛑', const Color(0xFF34C759)),
                      _CapChip('Plate OCR', '🔍', const Color(0xFF00D4FF)),
                    ],
                  ),
                  const Spacer(),
                  // Primary CTA
                  _PrimaryButton(
                    icon: Icons.videocam_rounded,
                    label: 'Start Detection',
                    gradient: const LinearGradient(
                      colors: [Color(0xFF00D4FF), Color(0xFF0080FF)],
                    ),
                    onTap: () => _handleStartDetection(context),
                  ),
                  const SizedBox(height: 14),
                  // Secondary buttons row
                  Row(
                    children: [
                      Expanded(
                        child: _SecondaryButton(
                          icon: Icons.layers_outlined,
                          label: 'Calibrations',
                          color: const Color(0xFF34C759),
                          onTap: () =>
                              Navigator.pushNamed(context, '/calibrations'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _SecondaryButton(
                          icon: Icons.history_rounded,
                          label: 'History',
                          color: const Color(0xFFFF9500),
                          onTap: () =>
                              Navigator.pushNamed(context, '/violations'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),
                ],
              ),
            ),
            // Settings button
            Positioned(
              top: 16,
              right: 16,
              child: GestureDetector(
                onTap: () => _showSettingsSheet(context),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.06),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white.withOpacity(0.1)),
                  ),
                  child: const Icon(
                    Icons.settings_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _BackgroundOrbs extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: -80,
          right: -60,
          child: Container(
            width: 300,
            height: 300,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF0080FF).withOpacity(0.15),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 100,
          left: -80,
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF00D4FF).withOpacity(0.1),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CapChip extends StatelessWidget {
  const _CapChip(this.label, this.emoji, this.color);
  final String label;
  final String emoji;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.gradient,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final LinearGradient gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 60,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0080FF).withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 7),
            Text(label,
                style: TextStyle(
                    color: color,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
