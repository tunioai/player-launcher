import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/storage_service.dart';

// Фирменные цвета Tunio
class TunioColors {
  static const Color primary = Color(0xFF434C58);
  static const Color primaryLight = Color(0xFF5A6370);
  static const Color primaryDark = Color(0xFF2D3440);
  static const Color accent = Color(0xFF434C58);
}

void main() {
  runApp(const TunioRadioApp());
}

class TunioRadioApp extends StatefulWidget {
  const TunioRadioApp({super.key});

  @override
  State<TunioRadioApp> createState() => _TunioRadioAppState();
}

class _TunioRadioAppState extends State<TunioRadioApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final storage = await StorageService.getInstance();
    final isDarkMode = storage.isDarkModeEnabled();
    setState(() {
      _themeMode = isDarkMode == null
          ? ThemeMode.system
          : (isDarkMode ? ThemeMode.dark : ThemeMode.light);
    });
  }

  Future<void> _toggleTheme() async {
    final storage = await StorageService.getInstance();
    setState(() {
      switch (_themeMode) {
        case ThemeMode.system:
          _themeMode = ThemeMode.light;
          storage.setDarkModeEnabled(false);
          break;
        case ThemeMode.light:
          _themeMode = ThemeMode.dark;
          storage.setDarkModeEnabled(true);
          break;
        case ThemeMode.dark:
          _themeMode = ThemeMode.system;
          storage.clearDarkModePreference();
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tunio Spot',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: TunioColors.primary,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: AppBarTheme(
          backgroundColor: TunioColors.primary,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: TunioColors.primary,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        appBarTheme: AppBarTheme(
          backgroundColor: TunioColors.primaryDark,
          foregroundColor: Colors.white,
          elevation: 2,
        ),
      ),
      home: HomeScreen(onThemeToggle: _toggleTheme, themeMode: _themeMode),
      debugShowCheckedModeBanner: false,
    );
  }
}
