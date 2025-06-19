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
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
