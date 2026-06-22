import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/calibration_screen.dart';
import 'screens/calibrations_list_screen.dart';
import 'screens/detection_screen.dart';
import 'screens/home_screen.dart';
import 'screens/violations_history_screen.dart';
import 'services/violation_processor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize background violation processing service
  await ViolationProcessor.instance.init();

  // Force portrait mode
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const ViolationDetectorApp());
}

class ViolationDetectorApp extends StatelessWidget {
  const ViolationDetectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Traffic Violation Detector',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      initialRoute: '/',
      routes: {
        '/': (_) => HomeScreen(),
        '/detect': (_) => const DetectionScreen(),
        '/calibrate': (_) => const CalibrationScreen(),
        '/violations': (_) => const ViolationsHistoryScreen(),
        '/calibrations': (_) => const CalibrationsListScreen(),
      },
    );
  }

  ThemeData _buildTheme() {
    return ThemeData(
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00D4FF),
        secondary: Color(0xFF0080FF),
        surface: Color(0xFF12121A),
        error: Color(0xFFFF3B30),
      ),
      scaffoldBackgroundColor: const Color(0xFF0A0A0F),
      fontFamily: 'Inter',
      useMaterial3: true,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF12121A),
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white.withOpacity(0.08),
        labelStyle: const TextStyle(color: Colors.white70),
        side: BorderSide(color: Colors.white.withOpacity(0.1)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}
