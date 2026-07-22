import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

import 'core/service_locator.dart';
import 'services/storage_service.dart';
import 'utils/platform_info.dart';

import 'screens/home_screen.dart';
import 'utils/logger.dart';
import 'utils/insecure_http_overrides.dart';

void main() {
  // Run everything inside a guarded zone so uncaught async errors land in the
  // on-disk log instead of vanishing. Native crashes (e.g. WebView2) still kill
  // the process, but the log keeps the last lines written right before them.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = InsecureHttpOverrides();

    await _initializeCrashLogging();

    // Framework (build/layout/paint) errors.
    FlutterError.onError = (details) {
      Logger.error('Flutter error', 'crash', details.exception, details.stack);
      FlutterError.presentError(details);
    };
    // Uncaught errors bubbling up to the engine (async gaps, platform channels).
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      Logger.error('Uncaught async error', 'crash', error, stack);
      return true;
    };

    // Foreground media service (Android only): keeps the app process alive
    // while a playback session is active, so background failover keeps running
    // with the screen off. Must run before any AudioPlayer is created.
    // Windows/macOS keep plain just_audio. androidNotificationOngoing requires
    // the default androidStopForegroundOnPause:true (asserted by audio_service).
    // Wrapped in try/catch so an init failure degrades to "no FGS", never a
    // black screen.
    if (Platform.isAndroid) {
      try {
        await JustAudioBackground.init(
          androidNotificationChannelId: 'ai.tunio.radioplayer.channel.audio',
          androidNotificationChannelName: 'Tunio Radio',
          androidNotificationOngoing: true,
        );
      } catch (e, stackTrace) {
        Logger.error('Background audio init failed', 'startup', e, stackTrace);
      }
    }

    await PlatformInfo.initialize();

    try {
      await ServiceLocator.initialize();
      Logger.info('Application services initialized successfully');
    } catch (e, stackTrace) {
      Logger.error('Failed to initialize services', 'startup', e, stackTrace);
      rethrow;
    }

    runApp(const TunioApp());
  }, (error, stack) {
    Logger.error('Uncaught zone error', 'crash', error, stack);
  });
}

/// Opens the persistent log file under the platform app-support directory
/// (Windows: %APPDATA%\Tunio AI\Tunio Spot\logs\tunio.log). Never throws.
Future<void> _initializeCrashLogging() async {
  // Verbose persists the full debug/info stream to disk; default keeps only
  // warnings/errors so we don't hammer the filesystem. Toggle at runtime with
  // TUNIO_VERBOSE=1 or at build time with --dart-define=VERBOSE_LOG=true.
  const verboseCompiled = bool.fromEnvironment('VERBOSE_LOG');
  final envVerbose = Platform.environment['TUNIO_VERBOSE'] == '1';
  final verbose = verboseCompiled || envVerbose;
  try {
    final supportDir = await getApplicationSupportDirectory();
    await Logger.initializeFileLogging(
        '${supportDir.path}${Platform.pathSeparator}logs',
        verbose: verbose);
    Logger.info('Log: ${Logger.logFilePath} verbose=$verbose', 'startup');
  } catch (e) {
    // ignore: avoid_print
    print('Failed to initialize crash logging: $e');
  }
}

class TunioApp extends StatefulWidget {
  const TunioApp({super.key});

  @override
  State<TunioApp> createState() => _TunioAppState();
}

class _TunioAppState extends State<TunioApp> with WidgetsBindingObserver {
  ThemeMode _themeMode = ThemeMode.system;
  late StorageService _storageService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupSystemUI();
    _loadThemePreference();
  }

  void _loadThemePreference() async {
    try {
      _storageService = await StorageService.getInstance();
      final isDarkModeEnabled = _storageService.isDarkModeEnabled();

      if (isDarkModeEnabled != null) {
        setState(() {
          _themeMode = isDarkModeEnabled ? ThemeMode.dark : ThemeMode.light;
        });
        Logger.info('Theme loaded: ${isDarkModeEnabled ? "Dark" : "Light"}');
      } else {
        Logger.info('No theme preference found, using system default');
      }
    } catch (e) {
      Logger.error('Failed to load theme preference: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _setupSystemUI() {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
    ));
  }

  void _toggleTheme() async {
    final newThemeMode =
        _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;

    setState(() {
      _themeMode = newThemeMode;
    });

    // Save theme preference
    try {
      await _storageService.setDarkModeEnabled(newThemeMode == ThemeMode.dark);
      Logger.info(
          'Theme saved: ${newThemeMode == ThemeMode.dark ? "Dark" : "Light"}');
    } catch (e) {
      Logger.error('Failed to save theme preference: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tunio Radio',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: _buildLightTheme(),
      darkTheme: _buildDarkTheme(),
      home: HomeScreen(
        onThemeToggle: _toggleTheme,
        themeMode: _themeMode,
      ),
    );
  }

  ThemeData _buildLightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: TunioColors.primary,
        secondary: TunioColors.secondary,
        surface: Colors.white,
        onSurface: Colors.black87,
      ),
      scaffoldBackgroundColor: Colors.grey[50],
      appBarTheme: const AppBarTheme(
        backgroundColor: TunioColors.primary,
        elevation: 0,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TunioColors.primary,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[100],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TunioColors.primary, width: 2),
        ),
      ),
    );
  }

  ThemeData _buildDarkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: TunioColors.primary,
        secondary: TunioColors.secondary,
        surface: Color(0xFF1E1E1E),
        onSurface: Colors.white,
      ),
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(
        backgroundColor: TunioColors.primary,
        elevation: 0,
        foregroundColor: Colors.white,
        titleTextStyle: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: TunioColors.primary,
          foregroundColor: Colors.white,
          elevation: 2,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.grey[850],
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: TunioColors.primary, width: 2),
        ),
      ),
    );
  }
}

/// App color constants
class TunioColors {
  static const Color primary = Color(0xFF48525C);
  static const Color primaryDark = Color(0xFF3A444E);
  static const Color secondary = Color(0xFF5A6670);
  static const Color accent = Color(0xFF06B6D4);
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
}
