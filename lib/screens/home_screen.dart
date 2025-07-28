import 'dart:async';
import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import '../core/dependency_injection.dart';
import '../core/service_locator.dart';
import '../core/audio_state.dart';

import '../services/radio_service.dart';
import '../services/failover_service.dart';
import '../widgets/code_input_widget.dart';
import '../widgets/status_indicator.dart';
import '../utils/logger.dart';
import '../main.dart' show TunioColors;

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
  late IRadioService _radioService;
  late IFailoverService _failoverService;
  bool _serviceInitialized = false;

  // Focus nodes for TV remote navigation
  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _connectButtonFocusNode = FocusNode();
  final FocusNode _playButtonFocusNode = FocusNode();
  final FocusNode _themeButtonFocusNode = FocusNode();

  // State
  String _currentCode = '';
  RadioState _radioState = const RadioStateDisconnected();
  NetworkState _networkState = const NetworkState();
  int? _currentPing;
  double _volume = 1.0;
  int _cachedTracksCount = 0;

  // Subscriptions
  StreamSubscription<RadioState>? _radioStateSubscription;
  StreamSubscription<NetworkState>? _networkStateSubscription;
  StreamSubscription<int?>? _pingSubscription;
  StreamSubscription<int>? _cachedTracksCountSubscription;

  @override
  void initState() {
    super.initState();
    _initializeService();
    _setupFocusNodes();
  }

  @override
  void dispose() {
    _radioStateSubscription?.cancel();
    _networkStateSubscription?.cancel();
    _pingSubscription?.cancel();
    _cachedTracksCountSubscription?.cancel();
    _codeFocusNode.dispose();
    _connectButtonFocusNode.dispose();
    _playButtonFocusNode.dispose();
    _themeButtonFocusNode.dispose();
    super.dispose();
  }

  void _setupFocusNodes() {
    _codeFocusNode.addListener(() => setState(() {}));
    _connectButtonFocusNode.addListener(() => setState(() {}));
    _playButtonFocusNode.addListener(() => setState(() {}));
    _themeButtonFocusNode.addListener(() => setState(() {}));
  }

  void _initializeService() {
    try {
      _radioService = di.radioService;
      _failoverService = di.failoverService;

      // Load saved PIN code immediately for UI display
      final storageService = di.storageService;
      final savedToken = storageService.getToken();
      if (savedToken != null && savedToken.isNotEmpty) {
        setState(() {
          _currentCode = savedToken;
        });
        Logger.info('HomeScreen: Loaded saved PIN code for display');
      }

      // Get current state immediately
      final currentRadioState = _radioService.currentState;
      setState(() {
        _radioState = currentRadioState;
        _currentPing = _radioService.currentPing;
        _cachedTracksCount = _failoverService.cachedTracksCount;

        // Update code from current state if available
        final token = currentRadioState.token;
        if (token != null && token != _currentCode) {
          _currentCode = token;
        }
      });

      // Set up streams for future changes
      _radioStateSubscription = _radioService.stateStream.listen((state) {
        if (mounted) {
          setState(() {
            _radioState = state;

            // Update code from token in state
            final token = state.token;
            if (token != null && token != _currentCode) {
              _currentCode = token;
            }

            // Update volume from config
            final config = state.config;
            if (config != null) {
              _volume = config.volume;
            }
          });
        }
      });

      _networkStateSubscription = _radioService.networkStream.listen((state) {
        if (mounted) {
          setState(() {
            _networkState = state;
          });
        }
      });

      _pingSubscription = _radioService.pingStream.listen((ping) {
        if (mounted) {
          setState(() {
            _currentPing = ping;
          });
        }
      });

      _cachedTracksCountSubscription =
          _failoverService.cachedTracksCountStream.listen((count) {
        if (mounted) {
          setState(() {
            _cachedTracksCount = count;
          });
        }
      });

      setState(() {
        _serviceInitialized = true;
      });

      Logger.info('HomeScreen: Service initialized successfully');
    } catch (e) {
      Logger.error('HomeScreen: Failed to initialize service: $e');
      _showError('Failed to initialize radio service');
    }
  }

  Future<void> _connect() async {
    if (_currentCode.isEmpty) {
      _showError('Please enter a PIN code');
      return;
    }

    Logger.info(
        'HomeScreen: Connecting with code: ${_currentCode.substring(0, 2)}****');

    final result = await _radioService.connect(_currentCode);
    result.fold(
      (_) {
        Logger.info('HomeScreen: Connection successful');
      },
      (error) {
        Logger.error('HomeScreen: Connection failed: $error');
        _showError(error);
      },
    );
  }

  Future<void> _playPause() async {
    final result = await _radioService.playPause();
    result.fold(
      (_) => Logger.info('HomeScreen: Play/pause successful'),
      (error) {
        Logger.error('HomeScreen: Play/pause failed: $error');
        _showError(error);
      },
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.withOpacity(0.9),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Dismiss',
          textColor: Colors.white,
          onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green.withOpacity(0.9),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () => ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
  }

  Future<void> _clearFailoverCache() async {
    try {
      Logger.info('HomeScreen: Clearing failover cache...');
      await _failoverService.clearCache();
      _showSuccess('Failover tracks cleared and will be re-downloaded');
    } catch (e) {
      Logger.error('HomeScreen: Failed to clear failover cache: $e');
      _showError('Failed to clear failover cache: $e');
    }
  }

  void _showVolumeInfo() {
    _showSuccess(
        'Volume is controlled from Tunio Link in your personal cabinet');
  }

  Future<void> _launchPersonalCabinet() async {
    const url = 'https://cp.tunio.ai/spot-links';
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  IconData _getThemeIcon() {
    return widget.themeMode == ThemeMode.dark
        ? Icons.light_mode
        : Icons.dark_mode;
  }

  String _getThemeTooltip() {
    return widget.themeMode == ThemeMode.dark
        ? 'Switch to light theme'
        : 'Switch to dark theme';
  }

  IconData _getPlayPauseIcon() {
    final audioState = _getAudioState();
    if (audioState?.isPlaying ?? false) {
      return Icons.pause;
    }
    return Icons.play_arrow;
  }

  AudioState? _getAudioState() {
    final audioState = switch (_radioState) {
      RadioStateConnected(:final audioState) => audioState,
      RadioStateFailover(:final audioState) => audioState,
      _ => null,
    };

    // Debug buffer value
    if (audioState is AudioStatePlaying) {
      Logger.info(
          '🎵 UI_DEBUG: UI reading AudioStatePlaying with buffer: ${audioState.bufferSize.inSeconds}s');
    }

    return audioState;
  }

  String _getStatusText() {
    return switch (_radioState) {
      RadioStateDisconnected(:final message) => message,
      RadioStateConnecting(:final message, :final attempt) =>
        '$message (attempt $attempt)',
      RadioStateConnected(:final audioState) => audioState.displayMessage,
      RadioStateFailover(:final audioState) =>
        'Failover: ${audioState.displayMessage}',
      RadioStateError(:final message, :final attemptCount) =>
        'Error: $message (attempt $attemptCount)',
    };
  }

  String _getDiagnosticText() {
    return switch (_radioState) {
      RadioStateConnecting(:final attempt) =>
        'Connecting... (attempt $attempt/∞)',
      RadioStateError(:final attemptCount, :final canRetry) => canRetry
          ? 'Retrying in 5s... (attempt $attemptCount/∞)'
          : 'Failed (attempt $attemptCount)',
      _ => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    if (!_serviceInitialized) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tunio Spot'),
        actions: [
          Focus(
            focusNode: _themeButtonFocusNode,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: _themeButtonFocusNode.hasFocus
                      ? TunioColors.primary
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
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // TIP Card - более компактная версия
            Card(
              color: Colors.grey[300],
              child: InkWell(
                onTap: _launchPersonalCabinet,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Row(
                    children: [
                      Icon(
                        Icons.lightbulb_outline,
                        color: TunioColors.primary,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'TIP: Get PIN code at cp.tunio.ai/spot-links',
                          style: TextStyle(
                            color: Colors.black87,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.open_in_new,
                        color: TunioColors.primary,
                        size: 14,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Connection Card - компактная версия
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CodeInputWidget(
                      value: _currentCode,
                      onChanged: (code) {
                        setState(() {
                          _currentCode = code;
                        });
                      },
                      onTap: () {
                        if (!_radioState.isConnected &&
                            !_radioState.isConnecting) {
                          setState(() {
                            _currentCode = '';
                          });
                        }
                      },
                      onSubmitted: () {
                        if (!_radioState.isConnecting) {
                          _connect();
                        }
                      },
                      enabled: !_radioState.isConnecting,
                      focusNode: _codeFocusNode,
                    ),
                    const SizedBox(height: 12),
                    Focus(
                      focusNode: _connectButtonFocusNode,
                      child: ElevatedButton.icon(
                        onPressed: _radioState.isConnecting ? null : _connect,
                        icon: _radioState.isConnecting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              )
                            : Icon(_radioState.isConnected
                                ? Icons.sync
                                : Icons.login),
                        label: Text(_radioState.isConnecting
                            ? 'Connecting...'
                            : (_radioState.isConnected
                                ? 'Change PIN & Reconnect'
                                : 'Connect')),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          backgroundColor: _radioState.isConnecting
                              ? TunioColors.primary.withOpacity(0.7)
                              : TunioColors.primary,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor:
                              TunioColors.primary.withOpacity(0.7),
                          disabledForegroundColor: Colors.white,
                          side: _connectButtonFocusNode.hasFocus
                              ? BorderSide(color: TunioColors.primary, width: 2)
                              : null,
                        ),
                      ),
                    ),

                    // Show connected status if connected
                    if (_radioState.isConnected)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Colors.green.withOpacity(0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check_circle,
                                color: Colors.green, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Connected - Running in Background',
                              style: TextStyle(
                                color: Colors.green,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Player Card (compact layout)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Text(
                      _radioState.config?.title ?? '',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        // Circular play/pause button
                        Focus(
                          focusNode: _playButtonFocusNode,
                          child: ElevatedButton(
                            onPressed:
                                _radioState.isConnected ? _playPause : null,
                            style: ElevatedButton.styleFrom(
                              shape: const CircleBorder(),
                              padding: const EdgeInsets.all(16),
                              side: _playButtonFocusNode.hasFocus
                                  ? BorderSide(
                                      color: TunioColors.primary, width: 3)
                                  : null,
                            ),
                            child: Icon(
                              _getPlayPauseIcon(),
                              size: 32,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Compact indicators
                        ..._buildCompactIndicators(),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Status indicator and metrics
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isMobile = constraints.maxWidth < 600;

                    if (isMobile) {
                      // Mobile layout: Column (status above, metrics below)
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Status indicator
                          StatusIndicator(
                            audioState:
                                _getAudioState() ?? const AudioStateIdle(),
                            isConnected: _radioState.isConnected,
                            statusMessage: _getStatusText(),
                          ),
                          const SizedBox(height: 16),

                          // Metrics chips in wrapped layout
                          _buildMetricsChips(),
                        ],
                      );
                    } else {
                      // Tablet/Desktop layout: Row (status left, metrics right)
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Status indicator (left side) - takes only needed space
                          StatusIndicator(
                            audioState:
                                _getAudioState() ?? const AudioStateIdle(),
                            isConnected: _radioState.isConnected,
                            statusMessage: _getStatusText(),
                          ),

                          // Metrics chips (right side) - aligned to right
                          _buildMetricsChips(),
                        ],
                      );
                    }
                  },
                ),
              ),
            ),

            // Диагностический индикатор внизу
            if (_radioState.isConnecting || _radioState is RadioStateError)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: _radioState.isConnecting
                      ? Colors.blue.withOpacity(0.1)
                      : Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _radioState.isConnecting
                        ? Colors.blue.withOpacity(0.3)
                        : Colors.red.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_radioState.isConnecting)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.blue),
                        ),
                      )
                    else
                      Icon(Icons.error_outline, size: 12, color: Colors.red),
                    const SizedBox(width: 6),
                    Text(
                      _getDiagnosticText(),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color:
                            _radioState.isConnecting ? Colors.blue : Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Status chip widget with icon and color
  Widget _buildStatusChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    Color? backgroundColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor ?? color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$label: $value',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCompactIndicators() {
    return [
      // Failover cache indicator (clickable to clear cache)
      GestureDetector(
        onTap: _clearFailoverCache,
        child: _buildSimpleLabel(
          icon: Icons.offline_pin,
          value: 'Offline: $_cachedTracksCount',
          color: _cachedTracksCount >= 5
              ? Colors.green
              : _cachedTracksCount >= 3
                  ? Colors.orange
                  : Colors.red,
        ),
      ),
      const SizedBox(width: 12),

      // Playback mode indicator
      if (_radioState.isConnected) ...[
        _buildSimpleLabel(
          icon: _radioState.isFailover ? Icons.offline_bolt : Icons.live_tv,
          value: _radioState.isFailover ? 'Failover' : 'Live',
          color: _radioState.isFailover ? Colors.orange : Colors.green,
        ),
        const SizedBox(width: 12),
      ],

      // Volume indicator (clickable with info)
      if (_radioState.isConnected)
        GestureDetector(
          onTap: _showVolumeInfo,
          child: _buildSimpleLabel(
            icon: Icons.volume_up,
            value: '${(_volume * 100).round()}%',
            color: Colors.blue,
          ),
        ),
    ];
  }

  Widget _buildSimpleLabel({
    required IconData icon,
    required String value,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricsChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        // Network status - show "Offline Mode" during failover
        _buildStatusChip(
          icon: _radioState.isFailover
              ? Icons.offline_bolt
              : (_networkState.isConnected ? Icons.wifi : Icons.wifi_off),
          label: 'Network',
          value: _radioState.isFailover
              ? 'Offline Mode'
              : (_networkState.isConnected ? 'Connected' : 'Disconnected'),
          color: _radioState.isFailover
              ? Colors.orange
              : (_networkState.isConnected ? Colors.green : Colors.red),
        ),

        // Stream ping if available
        if (_currentPing != null)
          _buildStatusChip(
            icon: Icons.speed,
            label: 'Ping',
            value: '${_currentPing}ms',
            color: _currentPing! < 100
                ? Colors.green
                : _currentPing! < 300
                    ? Colors.orange
                    : Colors.red,
          ),

        // Buffer status if playing
        if (_radioState is RadioStateConnected ||
            _radioState is RadioStateFailover)
          ..._buildAudioMetricChips(),
      ],
    );
  }

  List<Widget> _buildAudioMetricChips() {
    final audioState = _getAudioState();
    if (audioState is! AudioStatePlaying) return [];

    return [
      // Buffer size
      _buildStatusChip(
        icon: Icons.memory,
        label: 'Buffer',
        value: '${audioState.bufferSize.inSeconds}s',
        color: audioState.bufferSize.inSeconds >= 3
            ? Colors.green
            : audioState.bufferSize.inSeconds >= 1
                ? Colors.orange
                : Colors.red,
      ),

      // Quality
      _buildStatusChip(
        icon: Icons.high_quality,
        label: 'Quality',
        value: audioState.quality.displayName,
        color: audioState.quality == ConnectionQuality.excellent
            ? Colors.green
            : audioState.quality == ConnectionQuality.good
                ? Colors.lightGreen
                : audioState.quality == ConnectionQuality.fair
                    ? Colors.orange
                    : Colors.red,
      ),
    ];
  }
}
