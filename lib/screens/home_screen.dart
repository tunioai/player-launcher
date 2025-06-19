import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/radio_controller.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../services/autostart_service.dart';
import '../widgets/code_input_widget.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late RadioController _controller;
  late StorageService _storageService;

  // Focus nodes for TV remote navigation
  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _connectButtonFocusNode = FocusNode();
  final FocusNode _settingsButtonFocusNode = FocusNode();
  final FocusNode _playButtonFocusNode = FocusNode();
  final FocusNode _volumeFocusNode = FocusNode();

  String _currentCode = '';
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
    _storageService = await StorageService.getInstance();

    final isAutoStarted = await AutoStartService.isAutoStarted();
    if (isAutoStarted) {
      await _controller.handleAutoStart();
    }

    _controller.tokenStream.listen((token) {
      if (mounted) {
        setState(() {
          _currentCode = token ?? '';
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

  void _onCodeChanged(String code) {
    setState(() {
      _currentCode = code;
    });
  }

  Future<void> _connect() async {
    if (_currentCode.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter 6-digit code')),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
    });

    final success = await _controller.connectWithToken(_currentCode);

    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_statusMessage)),
      );
    }
  }

  Future<void> _disconnect() async {
    await _controller.disconnect();
    setState(() {
      _currentCode = '';
    });
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
    if (_isRetrying()) {
      return Colors.orange;
    }
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

  IconData _getConnectionIcon() {
    if (_isRetrying()) {
      return Icons.wifi_protected_setup;
    }
    if (_isConnected) {
      return Icons.radio;
    }
    return Icons.radio;
  }

  bool _isRetrying() {
    return _statusMessage.contains('attempt') ||
        _statusMessage.contains('retrying') ||
        _statusMessage.contains('Waiting for internet');
  }

  void _handleKeyPress(RawKeyEvent event) {
    if (event is RawKeyDownEvent) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.arrowLeft:
        case LogicalKeyboardKey.arrowRight:
          break;
        case LogicalKeyboardKey.select:
        case LogicalKeyboardKey.enter:
          final currentFocus = FocusScope.of(context).focusedChild;
          if (currentFocus != null) {
            if (currentFocus == _connectButtonFocusNode) {
              if (!_isConnecting) {
                _isConnected ? _disconnect() : _connect();
              }
            } else if (currentFocus == _playButtonFocusNode && _isConnected) {
              _togglePlayback();
            }
          }
          break;
        case LogicalKeyboardKey.mediaPlay:
        case LogicalKeyboardKey.mediaPlayPause:
          if (_isConnected) {
            _togglePlayback();
          }
          break;
        case LogicalKeyboardKey.escape:
          AutoStartService.openSystemLauncher();
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tunio Radio Player'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: FocusScope(
        child: RawKeyboardListener(
          focusNode: FocusNode(),
          onKey: _handleKeyPress,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: SingleChildScrollView(
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
                            'Connection',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          CodeInputWidget(
                            value: _currentCode,
                            onChanged: _onCodeChanged,
                            onSubmitted: () {
                              if (!_isConnecting && !_isConnected) {
                                _connect();
                              }
                            },
                            enabled: !_isConnected && !_isConnecting,
                            focusNode: _codeFocusNode,
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: Focus(
                                  focusNode: _connectButtonFocusNode,
                                  child: ElevatedButton.icon(
                                    onPressed: _isConnecting
                                        ? null
                                        : (_isConnected
                                            ? _disconnect
                                            : _connect),
                                    icon: _isConnecting
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2),
                                          )
                                        : Icon(_isConnected
                                            ? Icons.logout
                                            : Icons.login),
                                    label: Text(_isConnecting
                                        ? 'Connecting...'
                                        : (_isConnected
                                            ? 'Disconnect'
                                            : 'Connect')),
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      side: _connectButtonFocusNode.hasFocus
                                          ? const BorderSide(
                                              color: Colors.blue, width: 2)
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Focus(
                                focusNode: _settingsButtonFocusNode,
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: _settingsButtonFocusNode.hasFocus
                                          ? Colors.blue
                                          : Colors.transparent,
                                      width: 2,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: IconButton(
                                    onPressed: () async {
                                      await AutoStartService
                                          .openSystemLauncher();
                                    },
                                    icon: const Icon(Icons.settings),
                                    tooltip: 'Open System Launcher',
                                  ),
                                ),
                              ),
                            ],
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
                                _getConnectionIcon(),
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
                              if (_isRetrying()) ...[
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: _getStatusColor(),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (_currentTitle != null &&
                              _currentTitle!.isNotEmpty) ...[
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
                              Focus(
                                focusNode: _playButtonFocusNode,
                                child: ElevatedButton(
                                  onPressed:
                                      _isConnected ? _togglePlayback : null,
                                  style: ElevatedButton.styleFrom(
                                    shape: const CircleBorder(),
                                    padding: const EdgeInsets.all(16),
                                    side: _playButtonFocusNode.hasFocus
                                        ? const BorderSide(
                                            color: Colors.blue, width: 3)
                                        : null,
                                  ),
                                  child: Icon(
                                    _getPlayPauseIcon(),
                                    size: 32,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              const Icon(Icons.volume_down),
                              Expanded(
                                child: Focus(
                                  focusNode: _volumeFocusNode,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: _volumeFocusNode.hasFocus
                                            ? Colors.blue
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Slider(
                                      value: _volume,
                                      onChanged: _isConnected
                                          ? _onVolumeChanged
                                          : null,
                                      min: 0.0,
                                      max: 1.0,
                                      divisions: 20,
                                      label: '${(_volume * 100).round()}%',
                                      activeColor: _volumeFocusNode.hasFocus
                                          ? Colors.blue
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                              const Icon(Icons.volume_up),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _codeFocusNode.dispose();
    _connectButtonFocusNode.dispose();
    _settingsButtonFocusNode.dispose();
    _playButtonFocusNode.dispose();
    _volumeFocusNode.dispose();
    super.dispose();
  }
}
