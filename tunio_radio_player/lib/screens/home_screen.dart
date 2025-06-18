import 'package:flutter/material.dart';
import '../controllers/radio_controller.dart';
import '../services/audio_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late RadioController _controller;
  final TextEditingController _apiKeyController = TextEditingController();

  String? _currentApiKey;
  bool _isConnected = false;
  String _statusMessage = 'Ready';
  AudioState _audioState = AudioState.idle;
  String? _currentTitle;
  bool _isConnecting = false;
  double _volume = 1.0;

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  Future<void> _initializeController() async {
    _controller = await RadioController.getInstance();

    _controller.apiKeyStream.listen((apiKey) {
      if (mounted) {
        setState(() {
          _currentApiKey = apiKey;
          if (apiKey != null && apiKey.isNotEmpty) {
            _apiKeyController.text = apiKey;
          }
        });
      }
    });

    _controller.connectionStatusStream.listen((isConnected) {
      if (mounted) {
        setState(() {
          _isConnected = isConnected;
          _isConnecting = false;
        });
      }
    });

    _controller.statusMessageStream.listen((message) {
      if (mounted) {
        setState(() {
          _statusMessage = message;
        });
      }
    });

    _controller.audioStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _audioState = state;
        });
      }
    });

    _controller.titleStream.listen((title) {
      if (mounted) {
        setState(() {
          _currentTitle = title;
        });
      }
    });

    setState(() {
      _volume = _controller.volume;
    });
  }

  Future<void> _connect() async {
    if (_apiKeyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter API key')),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
    });

    final success =
        await _controller.connectWithApiKey(_apiKeyController.text.trim());

    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_statusMessage)),
      );
    }
  }

  Future<void> _disconnect() async {
    await _controller.disconnect();
    _apiKeyController.clear();
  }

  Future<void> _togglePlayback() async {
    await _controller.playPause();
  }

  Future<void> _onVolumeChanged(double value) async {
    setState(() {
      _volume = value;
    });
    await _controller.setVolume(value);
  }

  IconData _getPlayPauseIcon() {
    switch (_audioState) {
      case AudioState.playing:
        return Icons.pause;
      case AudioState.loading:
      case AudioState.buffering:
        return Icons.hourglass_empty;
      case AudioState.paused:
      case AudioState.idle:
        return Icons.play_arrow;
      case AudioState.error:
        return Icons.error;
    }
  }

  Color _getStatusColor() {
    if (_isConnected) {
      switch (_audioState) {
        case AudioState.playing:
          return Colors.green;
        case AudioState.loading:
        case AudioState.buffering:
          return Colors.orange;
        case AudioState.paused:
          return Colors.blue;
        case AudioState.error:
          return Colors.red;
        case AudioState.idle:
          return Colors.grey;
      }
    }
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tunio Radio Player'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'API Configuration',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _apiKeyController,
                      decoration: const InputDecoration(
                        labelText: 'API Key',
                        hintText: 'Enter your Tunio API key',
                        border: OutlineInputBorder(),
                      ),
                      enabled: !_isConnected && !_isConnecting,
                      obscureText: true,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _isConnecting
                          ? null
                          : (_isConnected ? _disconnect : _connect),
                      icon: _isConnecting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(_isConnected ? Icons.logout : Icons.login),
                      label: Text(_isConnecting
                          ? 'Connecting...'
                          : (_isConnected ? 'Disconnect' : 'Connect')),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.radio,
                          color: _getStatusColor(),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _statusMessage,
                            style: TextStyle(
                              color: _getStatusColor(),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_currentTitle != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _currentTitle!,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const Text(
                      'Playback Controls',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ElevatedButton(
                          onPressed: _isConnected ? _togglePlayback : null,
                          style: ElevatedButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(16),
                          ),
                          child: Icon(
                            _getPlayPauseIcon(),
                            size: 32,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Icon(Icons.volume_down),
                        Expanded(
                          child: Slider(
                            value: _volume,
                            onChanged: _isConnected ? _onVolumeChanged : null,
                            min: 0.0,
                            max: 1.0,
                            divisions: 20,
                            label: '${(_volume * 100).round()}%',
                          ),
                        ),
                        const Icon(Icons.volume_up),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            Card(
              color: Colors.blue.shade50,
              child: const Padding(
                padding: EdgeInsets.all(12.0),
                child: Column(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue),
                    SizedBox(height: 8),
                    Text(
                      'This app will automatically start and connect when your device boots up if an API key is saved.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }
}
