import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/storage_service.dart';

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
      title: 'Tunio Player',
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(onThemeToggle: _toggleTheme, themeMode: _themeMode),
      debugShowCheckedModeBanner: false,
    );
  }
}
