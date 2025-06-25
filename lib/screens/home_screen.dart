import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/dependency_injection.dart';
import '../core/service_locator.dart';
import '../core/audio_state.dart';

import '../services/radio_service.dart';
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
  bool _serviceInitialized = false;

  // Focus nodes for TV remote navigation
  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _connectButtonFocusNode = FocusNode();
  final FocusNode _playButtonFocusNode = FocusNode();
  final FocusNode _volumeFocusNode = FocusNode();
  final FocusNode _themeButtonFocusNode = FocusNode();
  final FocusNode _refreshButtonFocusNode = FocusNode();

  // State
  String _currentCode = '';
  RadioState _radioState = const RadioStateDisconnected();
  NetworkState _networkState = const NetworkState();
  double _volume = 1.0;

  // Subscriptions
  StreamSubscription<RadioState>? _radioStateSubscription;
  StreamSubscription<NetworkState>? _networkStateSubscription;

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
    _codeFocusNode.dispose();
    _connectButtonFocusNode.dispose();
    _playButtonFocusNode.dispose();
    _volumeFocusNode.dispose();
    _themeButtonFocusNode.dispose();
    _refreshButtonFocusNode.dispose();
    super.dispose();
  }

  void _setupFocusNodes() {
    _codeFocusNode.addListener(() => setState(() {}));
    _connectButtonFocusNode.addListener(() => setState(() {}));
    _playButtonFocusNode.addListener(() => setState(() {}));
    _volumeFocusNode.addListener(() => setState(() {}));
    _themeButtonFocusNode.addListener(() => setState(() {}));
    _refreshButtonFocusNode.addListener(() => setState(() {}));
  }

  void _initializeService() {
    try {
      _radioService = di.radioService;
      _volume = _radioService.volume;

      // Set up streams
      _radioStateSubscription = _radioService.stateStream.listen((state) {
        if (mounted) {
          setState(() {
            _radioState = state;

            // Update code from token in state
            final token = state.token;
            if (token != null && token != _currentCode) {
              _currentCode = token;
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
        _showSuccess('Connected successfully!');
      },
      (error) {
        Logger.error('HomeScreen: Connection failed: $error');
        _showError(error);
      },
    );
  }

  Future<void> _disconnect() async {
    final result = await _radioService.disconnect();
    result.fold(
      (_) {
        Logger.info('HomeScreen: Disconnected successfully');
        setState(() {
          _currentCode = '';
        });
      },
      (error) {
        Logger.error('HomeScreen: Disconnect failed: $error');
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

  Future<void> _reconnect() async {
    final result = await _radioService.reconnect();
    result.fold(
      (_) => Logger.info('HomeScreen: Reconnect successful'),
      (error) {
        Logger.error('HomeScreen: Reconnect failed: $error');
        _showError(error);
      },
    );
  }

  Future<void> _setVolume(double volume) async {
    final result = await _radioService.setVolume(volume);
    result.fold(
      (_) {
        setState(() {
          _volume = volume;
        });
      },
      (error) {
        Logger.error('HomeScreen: Set volume failed: $error');
        _showError(error);
      },
    );
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.withValues(alpha: 0.9),
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
        backgroundColor: Colors.green.withValues(alpha: 0.9),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(),
              const SizedBox(height: 32),
              _buildConnectionCard(),
              const SizedBox(height: 24),
              if (_radioState.isConnected) ...[
                _buildPlayerCard(),
                const SizedBox(height: 24),
                _buildStatsCard(),
              ],
              const Spacer(),
              _buildBottomActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tunio Radio',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: TunioColors.primary,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              _getStatusText(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        IconButton(
          focusNode: _themeButtonFocusNode,
          onPressed: widget.onThemeToggle,
          icon: Icon(
            widget.themeMode == ThemeMode.dark
                ? Icons.light_mode
                : Icons.dark_mode,
          ),
          style: IconButton.styleFrom(
            backgroundColor: _themeButtonFocusNode.hasFocus
                ? TunioColors.primary.withValues(alpha: 0.2)
                : null,
          ),
        ),
      ],
    );
  }

  String _getStatusText() {
    return switch (_radioState) {
      RadioStateDisconnected(:final message) => message,
      RadioStateConnecting(:final message) => message,
      RadioStateConnected(:final audioState) => audioState.displayMessage,
      RadioStateError(:final message) => 'Error: $message',
    };
  }

  Widget _buildConnectionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Connection',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: CodeInputWidget(
                    focusNode: _codeFocusNode,
                    value: _currentCode,
                    onChanged: (code) {
                      setState(() {
                        _currentCode = code;
                      });
                    },
                    enabled:
                        !_radioState.isConnecting && !_radioState.isConnected,
                  ),
                ),
                const SizedBox(width: 12),
                _buildConnectionButton(),
              ],
            ),
            if (_radioState.isConnected) ...[
              const SizedBox(height: 16),
              _buildConnectionInfo(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionButton() {
    if (_radioState.isConnected) {
      return ElevatedButton(
        focusNode: _connectButtonFocusNode,
        onPressed: _disconnect,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
        ),
        child: const Text('Disconnect'),
      );
    }

    return ElevatedButton(
      focusNode: _connectButtonFocusNode,
      onPressed: _radioState.isConnecting ? null : _connect,
      child: _radioState.isConnecting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Connect'),
    );
  }

  Widget _buildConnectionInfo() {
    final config = _radioState.config;
    if (config == null) return const SizedBox();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.radio,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              config.title ?? 'Unknown Station',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        StatusIndicator(
          audioState: _radioState is RadioStateConnected
              ? (_radioState as RadioStateConnected).audioState
              : const AudioStateIdle(),
          isConnected: _radioState.isConnected,
          statusMessage: _getStatusText(),
        ),
      ],
    );
  }

  Widget _buildPlayerCard() {
    final audioState = _getAudioState();
    if (audioState == null) return const SizedBox();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Player',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _buildPlayPauseButton(audioState),
                _buildReconnectButton(),
              ],
            ),
            const SizedBox(height: 20),
            _buildVolumeControl(),
          ],
        ),
      ),
    );
  }

  AudioState? _getAudioState() {
    return switch (_radioState) {
      RadioStateConnected(:final audioState) => audioState,
      _ => null,
    };
  }

  Widget _buildPlayPauseButton(AudioState audioState) {
    final isPlaying = audioState.isPlaying;
    final canPlay = audioState.canPlay;
    final canPause = audioState.canPause;

    return ElevatedButton.icon(
      focusNode: _playButtonFocusNode,
      onPressed: (canPlay || canPause) ? _playPause : null,
      icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
      label: Text(isPlaying ? 'Pause' : 'Play'),
      style: ElevatedButton.styleFrom(
        backgroundColor: isPlaying ? Colors.orange : TunioColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  Widget _buildReconnectButton() {
    return ElevatedButton.icon(
      focusNode: _refreshButtonFocusNode,
      onPressed: _reconnect,
      icon: const Icon(Icons.refresh),
      label: const Text('Reconnect'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    );
  }

  Widget _buildVolumeControl() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Volume: ${(_volume * 100).round()}%',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
        ),
        const SizedBox(height: 8),
        Focus(
          focusNode: _volumeFocusNode,
          child: Slider(
            value: _volume,
            onChanged: _setVolume,
            min: 0.0,
            max: 1.0,
            divisions: 20,
          ),
        ),
      ],
    );
  }

  Widget _buildStatsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connection Stats',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 16),
            _buildStatRow('Network',
                _networkState.isConnected ? 'Connected' : 'Disconnected'),
            _buildStatRow('Connection Type', _networkState.type.displayName),
            if (_networkState.pingMs != null)
              _buildStatRow('Ping', '${_networkState.pingMs}ms'),
            _buildAudioStats(),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioStats() {
    final audioState = _getAudioState();
    if (audioState is! AudioStatePlaying) return const SizedBox();

    return Column(
      children: [
        _buildStatRow('Buffer', '${audioState.bufferSize.inSeconds}s'),
        _buildStatRow('Quality', audioState.quality.displayName),
        _buildStatRow('Position', '${audioState.position.inSeconds}s'),
      ],
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton.icon(
          onPressed: () => SystemNavigator.pop(),
          icon: const Icon(Icons.exit_to_app),
          label: const Text('Exit'),
        ),
      ],
    );
  }
}
