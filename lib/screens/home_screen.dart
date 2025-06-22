import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../controllers/radio_controller.dart';
import '../services/audio_service.dart';
import '../services/autostart_service.dart';
import '../widgets/code_input_widget.dart';
import '../widgets/status_indicator.dart';
import '../utils/logger.dart';

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

  // Focus nodes for TV remote navigation
  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _connectButtonFocusNode = FocusNode();

  final FocusNode _playButtonFocusNode = FocusNode();
  final FocusNode _volumeFocusNode = FocusNode();
  final FocusNode _themeButtonFocusNode = FocusNode();
  final FocusNode _refreshButtonFocusNode = FocusNode();

  String _currentCode = '';
  bool _isConnected = false;
  String _statusMessage = 'Ready';
  AudioState _audioState = AudioState.idle;
  String? _currentTitle;
  bool _isConnecting = false;
  bool _isRetrying = false;
  double _volume = 1.0;
  String _connectionQuality = "Good";
  int? _currentPing;
  Duration _bufferSize = Duration.zero;
  bool _isNetworkAvailable = true;

  @override
  void initState() {
    super.initState();
    _initializeController();
    _setupFocusNodes();
  }

  void _setupFocusNodes() {
    // Setup focus node listeners for visual feedback
    _codeFocusNode.addListener(() => setState(() {}));
    _connectButtonFocusNode.addListener(() => setState(() {}));

    _playButtonFocusNode.addListener(() => setState(() {}));
    _volumeFocusNode.addListener(() => setState(() {}));
    _themeButtonFocusNode.addListener(() => setState(() {}));
    _refreshButtonFocusNode.addListener(() => setState(() {}));
  }

  Future<void> _initializeController() async {
    _controller = await RadioController.getInstance();

    // Initialize the current code from controller
    final initialToken = _controller.currentToken ?? '';
    Logger.debug(
        '🏠 HomeScreen: Initial token from controller: ${initialToken.isNotEmpty ? '${initialToken.substring(0, 2)}****' : 'EMPTY'}',
        'HomeScreen');
    setState(() {
      _currentCode = initialToken;
      // Don't set _isConnected here - let the stream handle it
    });

    // Set up ALL listeners first before triggering any start logic
    _controller.tokenStream.listen((token) {
      Logger.debug(
          '🏠 HomeScreen: Token stream updated: ${token != null ? '${token.substring(0, 2)}****' : 'NULL'}',
          'HomeScreen');
      if (mounted) {
        setState(() {
          _currentCode = token ?? '';
        });
      }
    });

    _controller.connectionStatusStream.listen((isConnected) {
      Logger.debug('🏠 HomeScreen: Connection status updated: $isConnected',
          'HomeScreen');
      if (mounted) {
        setState(() {
          _isConnected = isConnected;
          _isConnecting = false;
        });
      }
    });

    _controller.statusMessageStream.listen((message) {
      Logger.debug(
          '🏠 HomeScreen: Status message updated: $message', 'HomeScreen');
      if (mounted) {
        setState(() {
          _statusMessage = message;
        });
      }
    });

    _controller.audioStateStream.listen((state) {
      Logger.debug('🏠 HomeScreen: Audio state updated: $state', 'HomeScreen');
      if (mounted) {
        setState(() {
          _audioState = state;
        });
      }
    });

    _controller.titleStream.listen((title) {
      Logger.debug('🏠 HomeScreen: Title updated: $title', 'HomeScreen');
      if (mounted) {
        setState(() {
          _currentTitle = title;
        });
      }
    });

    // Listen for retry state changes
    _controller.retryStateStream.listen((isRetrying) {
      Logger.debug(
          '🏠 HomeScreen: Retry state updated: $isRetrying', 'HomeScreen');
      if (mounted) {
        setState(() {
          _isRetrying = isRetrying;
        });
      }
    });

    // Listen for error notifications and show snackbar
    _controller.errorNotificationStream.listen((errorMessage) {
      Logger.debug(
          '🏠 HomeScreen: Error notification: $errorMessage', 'HomeScreen');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errorMessage),
            backgroundColor: Colors.red.withValues(alpha: 0.9),
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

    // Listen for connection quality updates (replaces buffer display)
    _controller.connectionQualityStream.listen((quality) {
      Logger.debug('🏠 HomeScreen: Connection quality: $quality', 'HomeScreen');
      if (mounted) {
        setState(() {
          _connectionQuality = quality;
        });
      }
    });

    _controller.pingStream.listen((ping) {
      Logger.debug('🏠 HomeScreen: Ping: ${ping}ms', 'HomeScreen');
      if (mounted) {
        setState(() {
          _currentPing = ping;
        });
      }
    });

    _controller.bufferStream.listen((buffer) {
      Logger.debug('🏠 HomeScreen: Buffer: ${buffer.inSeconds}s', 'HomeScreen');
      if (mounted) {
        setState(() {
          _bufferSize = buffer;
        });
      }
    });

    _controller.networkService.connectivityStream.listen((isConnected) {
      Logger.debug(
          '🏠 HomeScreen: Network available: $isConnected', 'HomeScreen');
      if (mounted) {
        setState(() {
          _isNetworkAvailable = isConnected;
        });
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

  Future<void> _launchPersonalCabinet() async {
    final uri = Uri.parse('https://cp.tunio.ai');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Could not open browser. Please visit cp.tunio.ai manually'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Could not open browser. Please visit cp.tunio.ai manually'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  KeyEventResult _handleKeyPress(KeyEvent event) {
    if (event is KeyDownEvent) {
      final currentFocus = FocusScope.of(context).focusedChild;

      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.arrowLeft:
        case LogicalKeyboardKey.arrowRight:
          // Handle volume control when volume slider is focused
          if (currentFocus == _volumeFocusNode && _isConnected) {
            double newVolume = _volume;
            if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                event.logicalKey == LogicalKeyboardKey.arrowUp) {
              newVolume = (_volume + 0.05).clamp(0.0, 1.0);
            } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.arrowDown) {
              newVolume = (_volume - 0.05).clamp(0.0, 1.0);
            }
            if (newVolume != _volume) {
              _onVolumeChanged(newVolume);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;

        case LogicalKeyboardKey.select:
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.space:
          if (currentFocus != null) {
            if (currentFocus == _connectButtonFocusNode) {
              if (!_isConnecting) {
                _isConnected ? _disconnect() : _connect();
              }
              return KeyEventResult.handled;
            } else if (currentFocus == _playButtonFocusNode && _isConnected) {
              _togglePlayback();
              return KeyEventResult.handled;
            } else if (currentFocus == _themeButtonFocusNode) {
              widget.onThemeToggle();
              return KeyEventResult.handled;
            } else if (currentFocus == _refreshButtonFocusNode) {
              _controller.reconnect();
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

        case LogicalKeyboardKey.mediaStop:
          if (_isConnected) {
            _disconnect();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;

        case LogicalKeyboardKey.audioVolumeUp:
          if (_isConnected) {
            _onVolumeChanged((_volume + 0.1).clamp(0.0, 1.0));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;

        case LogicalKeyboardKey.audioVolumeDown:
          if (_isConnected) {
            _onVolumeChanged((_volume - 0.1).clamp(0.0, 1.0));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;

        case LogicalKeyboardKey.escape:
        case LogicalKeyboardKey.goBack:
          // User can exit the app manually if needed
          return KeyEventResult.handled;

        // Number keys for code input
        case LogicalKeyboardKey.digit0:
        case LogicalKeyboardKey.digit1:
        case LogicalKeyboardKey.digit2:
        case LogicalKeyboardKey.digit3:
        case LogicalKeyboardKey.digit4:
        case LogicalKeyboardKey.digit5:
        case LogicalKeyboardKey.digit6:
        case LogicalKeyboardKey.digit7:
        case LogicalKeyboardKey.digit8:
        case LogicalKeyboardKey.digit9:
          if (currentFocus == _codeFocusNode &&
              !_isConnected &&
              !_isConnecting) {
            final digit = event.logicalKey.keyLabel;
            if (_currentCode.length < 6) {
              _onCodeChanged(_currentCode + digit);
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;

        case LogicalKeyboardKey.backspace:
          if (currentFocus == _codeFocusNode &&
              !_isConnected &&
              !_isConnecting) {
            if (_currentCode.isNotEmpty) {
              _onCodeChanged(
                  _currentCode.substring(0, _currentCode.length - 1));
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tunio Player'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          Focus(
            focusNode: _themeButtonFocusNode,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: _themeButtonFocusNode.hasFocus
                      ? Colors.blue
                      : Colors.transparent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                onPressed: widget.onThemeToggle,
                icon: Icon(_getThemeIcon()),
                tooltip: _getThemeTooltip(),
              ),
            ),
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
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    child: InkWell(
                      onTap: _launchPersonalCabinet,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Row(
                          children: [
                            Icon(
                              Icons.lightbulb_outline,
                              color: Theme.of(context).colorScheme.primary,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: RichText(
                                text: TextSpan(
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSecondaryContainer,
                                    fontSize: 14,
                                  ),
                                  children: [
                                    const TextSpan(
                                      text: 'TIP: ',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold),
                                    ),
                                    const TextSpan(
                                      text:
                                          'You can get the broadcast PIN code in your personal account ',
                                    ),
                                    TextSpan(
                                      text: 'cp.tunio.ai',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        fontWeight: FontWeight.w600,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Icon(
                              Icons.open_in_new,
                              color: Theme.of(context).colorScheme.primary,
                              size: 16,
                            ),
                          ],
                        ),
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
                        children: [
                          Text(
                            _currentTitle ?? '',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
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
                              const SizedBox(width: 16),
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
                  const SizedBox(height: 16),
                  StreamNetworkIndicator(
                    audioState: _audioState,
                    isConnected: _isConnected,
                    connectionQuality: _connectionQuality,
                    bufferSize: _bufferSize,
                    pingMs: _currentPing,
                    reconnectCount: _controller.reconnectCount,
                    isNetworkAvailable: _isNetworkAvailable,
                    statusMessage: _statusMessage,
                    isRetrying: _isRetrying,
                    onReconnect: () async {
                      await _controller.reconnect();
                    },
                    refreshButtonFocusNode: _refreshButtonFocusNode,
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

    _playButtonFocusNode.dispose();
    _volumeFocusNode.dispose();
    _themeButtonFocusNode.dispose();
    _refreshButtonFocusNode.dispose();
    super.dispose();
  }
}
