import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/dashboard_screen.dart';
import 'services/background_service.dart';

class EspressoPalette {
  static const Color background = Color(0xFF17120E);
  static const Color cardEspresso = Color(0xFF211914);
  static const Color cardBrown = Color(0xFF432B1D);
  static const Color batteryTrack = Color(0xFF28220B);
  static const Color batteryFill = Color(0xFF565214);
  static const Color creamText = Color(0xFFF7EFEA);
  static const Color peachAccent = Color(0xFFFFCCA7);
  static const Color sandAccent = Color(0xFFD5B195);
  static const Color lightCreamPill = Color(0xFFFCEEE9);
  static const Color darkPillText = Color(0xFF231914);
  static const Color chartLine = Color(0xFFF3E2A7);
  static const Color chartFillTop = Color(0x55C4A459);
  static const Color chartFillBottom = Color(0x00C4A459);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-warm SharedPreferences on the main engine before Workmanager registers
  try {
    await SharedPreferences.getInstance();
  } catch (e) {
    debugPrint('SharedPreferences pre-warm warning: $e');
  }

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: EspressoPalette.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Schedule 15-minute Workmanager periodic sync for CareLink/xDrip -> Health Connect & Widget
  await BackgroundSyncService.initializeAndSchedule();

  runApp(const MinimedPixelBridgeApp());
}

class MinimedPixelBridgeApp extends StatelessWidget {
  const MinimedPixelBridgeApp({super.key});

  static final ColorScheme _fallbackDarkScheme = ColorScheme.fromSeed(
    seedColor: EspressoPalette.cardBrown,
    brightness: Brightness.dark,
    primary: EspressoPalette.peachAccent,
    onPrimary: EspressoPalette.darkPillText,
    secondary: EspressoPalette.sandAccent,
    onSecondary: EspressoPalette.darkPillText,
    surface: EspressoPalette.cardBrown,
    onSurface: EspressoPalette.creamText,
  );

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final ColorScheme scheme = (darkDynamic ?? _fallbackDarkScheme).copyWith(
          surface: EspressoPalette.cardBrown,
          onSurface: EspressoPalette.creamText,
          primary: darkDynamic?.primary ?? EspressoPalette.peachAccent,
          secondary: darkDynamic?.secondary ?? EspressoPalette.sandAccent,
        );

        return MaterialApp(
          title: 'MiniMed Pixel Bridge',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: scheme,
            scaffoldBackgroundColor: EspressoPalette.background,
            appBarTheme: const AppBarTheme(
              backgroundColor: EspressoPalette.background,
              foregroundColor: EspressoPalette.creamText,
              surfaceTintColor: Colors.transparent,
            ),
            snackBarTheme: SnackBarThemeData(
              backgroundColor: EspressoPalette.cardBrown,
              contentTextStyle: const TextStyle(color: EspressoPalette.creamText),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              behavior: SnackBarBehavior.floating,
            ),
          ),
          home: const DashboardScreen(),
        );
      },
    );
  }
}
