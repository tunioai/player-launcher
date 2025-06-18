import 'package:flutter/material.dart';
import 'controllers/radio_controller.dart';
import 'screens/home_screen.dart';

void main() {
  runApp(const TunioRadioApp());
}

class TunioRadioApp extends StatelessWidget {
  const TunioRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tunio Radio Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const AppInitializer(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class AppInitializer extends StatefulWidget {
  const AppInitializer({super.key});

  @override
  State<AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer> {
  bool _isInitializing = true;
  String _initializationStatus = 'Initializing...';

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      setState(() {
        _initializationStatus = 'Setting up audio services...';
      });

      final controller = await RadioController.getInstance();

      setState(() {
        _initializationStatus = 'Checking for auto-start...';
      });

      await Future.delayed(const Duration(milliseconds: 500));

      await controller.handleAutoStart();

      setState(() {
        _isInitializing = false;
      });
    } catch (e) {
      setState(() {
        _initializationStatus = 'Initialization failed: $e';
      });

      await Future.delayed(const Duration(seconds: 2));

      setState(() {
        _isInitializing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                _initializationStatus,
                style: const TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Image.asset(
                'assets/images/logo.png',
                width: 100,
                height: 100,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(
                    Icons.radio,
                    size: 100,
                    color: Colors.deepPurple,
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    return const HomeScreen();
  }
}
