import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../controllers/radio_controller.dart';
import '../services/audio_service.dart';
import '../services/storage_service.dart';
import '../services/autostart_service.dart';
import '../widgets/code_input_widget.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback onThemeToggle;
  final ThemeMode themeMode;

  const HomeScreen({
    super.key,
    required this.onThemeToggle,
    required this.themeMode,
  });

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
  bool _isRetrying = false;
  double _volume = 1.0;

  @override
  void initState() {
    super.initState();
    _initializeController();
  }

  Future<void> _initializeController() async {
    _controller = await RadioController.getInstance();
    _storageService = await StorageService.getInstance();

    // Initialize the current code from controller
    final initialToken = _controller.currentToken ?? '';
    print(
        '🏠 HomeScreen: Initial token from controller: ${initialToken.isNotEmpty ? '${initialToken.substring(0, 2)}****' : 'EMPTY'}');
    setState(() {
      _currentCode = initialToken;
      // Don't set _isConnected here - let the stream handle it
    });

    // Set up ALL listeners first before triggering any start logic
    _controller.tokenStream.listen((token) {
      print(
          '🏠 HomeScreen: Token stream updated: ${token != null ? '${token.substring(0, 2)}****' : 'NULL'}');
      if (mounted) {
        setState(() {
          _currentCode = token ?? '';
        });
      }
    });

    _controller.connectionStatusStream.listen((isConnected) {
      print('🏠 HomeScreen: Connection status updated: $isConnected');
      if (mounted) {
        setState(() {
          _isConnected = isConnected;
          _isConnecting = false;
        });
      }
    });

    _controller.statusMessageStream.listen((message) {
      print('🏠 HomeScreen: Status message updated: $message');
      if (mounted) {
        setState(() {
          _statusMessage = message;
        });
      }
    });

    _controller.audioStateStream.listen((state) {
      print('🏠 HomeScreen: Audio state updated: $state');
      if (mounted) {
        setState(() {
          _audioState = state;
        });
      }
    });

    _controller.titleStream.listen((title) {
      print('🏠 HomeScreen: Title updated: $title');
      if (mounted) {
        setState(() {
          _currentTitle = title;
        });
      }
    });

    // Listen for retry state changes
    _controller.retryStateStream.listen((isRetrying) {
      print('🏠 HomeScreen: Retry state updated: $isRetrying');
      if (mounted) {
        setState(() {
          _isRetrying = isRetrying;
        });
      }
    });

    // Listen for error notifications and show snackbar
    _controller.errorNotificationStream.listen((errorMessage) {
      print('🏠 HomeScreen: Error notification: $errorMessage');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red.withOpacity(0.9),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
            action: SnackBarAction(
              label: 'Dismiss',
              textColor: Colors.white,
              onPressed: () {
                ScaffoldMessenger.of(context).hideCurrentSnackBar();
              },
            ),
          ),
        );
      }
    });

    // Now trigger the startup logic after ALL listeners are set up
    final isAutoStarted = await AutoStartService.isAutoStarted();
    if (isAutoStarted) {
      await _controller.handleAutoStart();
    } else {
      // Handle normal app start
      await _controller.handleNormalStart();
    }

    // Sync UI with current controller state after startup
    if (mounted) {
      setState(() {
        _volume = _controller.volume;
        _isConnected = _controller.isConnected;
        _audioState = _controller.audioState;
        _isRetrying = _controller.isRetrying;
        // Status message and title will be updated via streams
      });
    }
  }

  void _onCodeChanged(String code) {
    setState(() {
      _currentCode = code;
    });
  }

  Future<void> _connect() async {
    if (_currentCode.length != 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter 6-digit code'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
    });

    // Connect - errors will be handled by errorNotificationStream listener
    await _controller.connectWithToken(_currentCode);
  }

  Future<void> _disconnect() async {
    await _controller.disconnect();
    // Don't clear _currentCode here - let tokenStream handle it
    // This ensures UI stays in sync with the actual token state
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
    if (_isRetrying) {
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
    if (_isRetrying) {
      return Icons.wifi_protected_setup;
    }
    if (_isConnected) {
      return Icons.radio;
    }
    return Icons.radio;
  }

  IconData _getThemeIcon() {
    switch (widget.themeMode) {
      case ThemeMode.system:
        return Icons.brightness_auto;
      case ThemeMode.light:
        return Icons.light_mode;
      case ThemeMode.dark:
        return Icons.dark_mode;
    }
  }

  String _getThemeTooltip() {
    switch (widget.themeMode) {
      case ThemeMode.system:
        return 'Auto theme (tap for light)';
      case ThemeMode.light:
        return 'Light theme (tap for dark)';
      case ThemeMode.dark:
        return 'Dark theme (tap for auto)';
    }
  }

  KeyEventResult _handleKeyPress(KeyEvent event) {
    if (event is KeyDownEvent) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.arrowLeft:
        case LogicalKeyboardKey.arrowRight:
          return KeyEventResult.ignored;
        case LogicalKeyboardKey.select:
        case LogicalKeyboardKey.enter:
          final currentFocus = FocusScope.of(context).focusedChild;
          if (currentFocus != null) {
            if (currentFocus == _connectButtonFocusNode) {
              if (!_isConnecting) {
                _isConnected ? _disconnect() : _connect();
              }
              return KeyEventResult.handled;
            } else if (currentFocus == _playButtonFocusNode && _isConnected) {
              _togglePlayback();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        case LogicalKeyboardKey.mediaPlay:
        case LogicalKeyboardKey.mediaPlayPause:
          if (_isConnected) {
            _togglePlayback();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        case LogicalKeyboardKey.escape:
          AutoStartService.openSystemLauncher();
          return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tunio Radio Player'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            onPressed: widget.onThemeToggle,
            icon: Icon(_getThemeIcon()),
            tooltip: _getThemeTooltip(),
          ),
        ],
      ),
      body: FocusScope(
        child: KeyboardListener(
          focusNode: FocusNode(),
          onKeyEvent: _handleKeyPress,
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
                              if (_isRetrying) ...[
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
                              if (_statusMessage.contains('error') &&
                                  !_statusMessage.contains('retrying') &&
                                  !_isConnecting) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  onPressed: () async {
                                    await _controller.reconnect();
                                  },
                                  icon: const Icon(Icons.refresh),
                                  iconSize: 20,
                                  tooltip: 'Reconnect',
                                  color: Colors.blue,
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
