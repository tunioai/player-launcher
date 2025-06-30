import 'dart:async';
import 'dart:io';

import '../core/result.dart';
import '../core/dependency_injection.dart';
import '../core/audio_state.dart';
import '../models/stream_config.dart';
import '../models/api_error.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../utils/logger.dart';
import 'audio_service.dart';

/// Interface for radio service
abstract interface class IRadioService implements Disposable {
  Stream<RadioState> get stateStream;
  Stream<NetworkState> get networkStream;
  Stream<int?> get pingStream;
  RadioState get currentState;

  Future<Result<void>> initialize();
  Future<Result<void>> connect(String token);
  Future<Result<void>> disconnect();
  Future<Result<void>> playPause();
  Future<Result<void>> setVolume(double volume);
  Future<Result<void>> reconnect();

  bool get isConnected;
  double get volume;
  int? get currentPing;
}

/// Enhanced RadioService with proper error handling and state management
final class EnhancedRadioService implements IRadioService {
  final IAudioService _audioService;
  final ApiService _apiService;
  final StorageService _storageService;

  // State management
  final StreamController<RadioState> _stateController =
      StreamController<RadioState>.broadcast();
  RadioState _currentState = const RadioStateDisconnected();

  // Ping management
  final StreamController<int?> _pingController =
      StreamController<int?>.broadcast();
  int? _currentPing;
  Timer? _pingTimer;

  // Subscriptions
  StreamSubscription<AudioState>? _audioStateSubscription;
  StreamSubscription<NetworkState>? _networkStateSubscription;

  // Configuration polling
  Timer? _configPollingTimer;
  static const Duration _configPollingInterval = Duration(minutes: 1);

  // Retry management
  final RetryManager _retryManager = RetryManager();
  Timer? _retryTimer;

  // State monitoring for hung connections - CRITICAL for device reliability
  Timer? _stateMonitorTimer;
  DateTime? _connectingStateStartTime;
  Timer? _forceRecoveryTimer;
  String?
      _currentConnectionStage; // Track which stage we're in for better diagnostics

  // Auto-start and reconnection
  bool _autoReconnectEnabled = false;

  // Initialization
  final Completer<void> _initializationCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _isDisposed = false;

  EnhancedRadioService({
    required IAudioService audioService,
    required ApiService apiService,
    required StorageService storageService,
  })  : _audioService = audioService,
        _apiService = apiService,
        _storageService = storageService;

  @override
  Stream<RadioState> get stateStream => _stateController.stream;

  @override
  Stream<NetworkState> get networkStream => _audioService.networkStream;

  @override
  Stream<int?> get pingStream => _pingController.stream;

  @override
  RadioState get currentState => _currentState;

  @override
  bool get isConnected => _currentState.isConnected;

  @override
  double get volume => _audioService.volume;

  @override
  int? get currentPing => _currentPing;

  @override
  Future<Result<void>> initialize() async {
    if (_isInitialized) return const Success(null);
    if (_initializationCompleter.isCompleted) {
      await _initializationCompleter.future;
      return const Success(null);
    }

    return tryResultAsync(() async {
      // Initialize audio service first
      final audioInitResult = await _audioService.initialize();
      if (audioInitResult.isFailure) {
        throw Exception(
            'Failed to initialize audio service: ${audioInitResult.error}');
      }

      _setupSubscriptions();
      await _restoreState();

      _isInitialized = true;
      _initializationCompleter.complete();

      Logger.info('RadioService: Initialized successfully');
    });
  }

  void _setupSubscriptions() {
    // Audio state changes
    _audioStateSubscription = _audioService.stateStream.listen(
      _handleAudioStateChange,
      onError: (error) => Logger.error('Audio state stream error: $error'),
    );

    // Network state changes for auto-reconnection
    _networkStateSubscription = _audioService.networkStream.listen(
      _handleNetworkStateChange,
      onError: (error) => Logger.error('Network state stream error: $error'),
    );

    // Start state monitoring for hung connections
    _startStateMonitoring();
  }

  void _handleAudioStateChange(AudioState audioState) {
    Logger.info('Audio state changed: ${audioState.runtimeType}');

    // Update radio state based on audio state
    switch (_currentState) {
      case RadioStateConnected connected:
        final newState = connected.copyWith(audioState: audioState);
        _updateState(newState);

        // Handle error states - faster detection for stream loss
        if (audioState is AudioStateError && audioState.isRetryable) {
          Logger.warning('Audio error detected: ${audioState.message}');

          // Faster detection - wait only 3 seconds for stream loss
          Timer(const Duration(seconds: 3), () {
            // Check if we're still in error state after delay
            if (_currentState is RadioStateConnected) {
              final currentAudioState =
                  (_currentState as RadioStateConnected).audioState;
              if (currentAudioState is AudioStateError &&
                  currentAudioState.isRetryable) {
                Logger.error('Stream lost - immediate retry');
                _scheduleRetry('Stream lost: ${currentAudioState.message}');
              } else {
                Logger.info('Audio error resolved automatically');
              }
            }
          });
        }

      case RadioStateConnecting _:
        // Check if we successfully started playing
        if (audioState.isPlaying) {
          // We should have config at this point
          final config = audioState.config;
          final token = _getStoredToken();
          if (config != null && token != null) {
            _updateState(RadioStateConnected(
              token: token,
              config: config,
              audioState: audioState,
            ));
            _retryManager.reset();
            _startConfigPolling();
            _startPinging(config.streamUrl);
          }
        }

      default:
        // Other states don't need audio state updates
        break;
    }
  }

  void _handleNetworkStateChange(NetworkState networkState) {
    Logger.info('Network state changed: connected=${networkState.isConnected}');

    if (networkState.isConnected && _autoReconnectEnabled) {
      // Network restored, attempt reconnection if needed
      final shouldReconnect = _currentState is RadioStateError ||
          _currentState is RadioStateDisconnected ||
          (_currentState is RadioStateConnecting && _isConnectingTooLong());

      if (shouldReconnect) {
        final token = _getStoredToken();
        if (token != null) {
          Logger.info(
              'Network restored, attempting auto-reconnection (current state: ${_currentState.runtimeType})');
          // Cancel any existing retry timer before starting new attempt
          _retryTimer?.cancel();
          _retryManager.reset();

          // Reset hung state tracking for fresh start
          _connectingStateStartTime = null;

          unawaited(_attemptConnect(token, isRetry: true));
        }
      }
    }
  }

  bool _isConnectingTooLong() {
    if (_connectingStateStartTime == null) return false;

    final timeInConnecting =
        DateTime.now().difference(_connectingStateStartTime!);
    // Consider connecting "too long" if more than 15 seconds
    return timeInConnecting.inSeconds > 15;
  }

  Future<void> _restoreState() async {
    final token = _getStoredToken();
    if (token != null) {
      Logger.info('Restoring connection with stored token');
      _autoReconnectEnabled = true;

      // Use unawaited for startup connection - let the state machine handle success/failure
      // This prevents false "Auto-reconnect failed" messages when audio takes time to start
      Logger.info('Starting background connection attempt...');
      unawaited(_attemptConnect(token, isRetry: false).then((result) {
        if (result.isFailure) {
          Logger.warning('Auto-reconnect failed: ${result.error}');
          // Only schedule retry if we're not already connected
          if (!_currentState.isConnected) {
            _scheduleRetry('Auto-reconnect failed on startup');
          } else {
            Logger.info(
                'Auto-reconnect reported failure but we are connected - ignoring');
          }
        } else {
          Logger.info('Auto-reconnect completed successfully');
        }
      }));
    } else {
      Logger.info('No stored token found');
      _updateState(const RadioStateDisconnected(message: 'Ready'));
    }
  }

  String? _getStoredToken() => _storageService.getToken();

  @override
  Future<Result<void>> connect(String token) async {
    if (!_isInitialized) {
      final initResult = await initialize();
      if (initResult.isFailure) return initResult;
    }

    _retryManager.reset();
    _autoReconnectEnabled = true;

    return _attemptConnect(token, isRetry: false);
  }

  Future<Result<void>> _attemptConnect(String token,
      {required bool isRetry}) async {
    final attempt = isRetry ? _retryManager.currentAttempt + 1 : 1;

    _updateState(RadioStateConnecting(
      message: isRetry ? 'Reconnecting...' : 'Connecting...',
      attempt: attempt,
    ));

    Logger.info('Attempting connection (attempt $attempt)');

    // Add timeout for connecting state to prevent infinite "Reconnecting"
    // Reduced from 45s to 20s for faster hung detection in autonomous devices
    final connectingTimeout = Timer(const Duration(seconds: 20), () {
      if (_currentState is RadioStateConnecting) {
        Logger.error('Connection attempt timed out after 20 seconds');
        _scheduleRetry('Connection timeout - retrying');
      }
    });

    try {
      final result = await tryResultAsync(() async {
        await _performConnection(token);
      });

      connectingTimeout.cancel();
      return result;
    } catch (e) {
      connectingTimeout.cancel();
      rethrow;
    }
  }

  Future<void> _performConnection(String token) async {
    Logger.info('🔄 CONNECTION: ===== STARTING CONNECTION PROCESS =====');
    final connectionStartTime = DateTime.now();

    try {
      // STAGE 1: Fetch stream configuration with timeout
      _currentConnectionStage = 'API_REQUEST';
      Logger.info('🔄 CONNECTION: STAGE 1 - Fetching stream configuration...');
      final apiStartTime = DateTime.now();

      final config = await _apiService.getStreamConfig(token).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          final elapsed = DateTime.now().difference(apiStartTime);
          Logger.error(
              '🔄 CONNECTION: API request timed out after ${elapsed.inSeconds}s');
          throw TimeoutException('API request timed out');
        },
      );

      if (config == null) {
        throw ApiError(
            message: 'Invalid token or server error', isFromBackend: true);
      }

      final apiDuration = DateTime.now().difference(apiStartTime);
      Logger.info(
          '🔄 CONNECTION: STAGE 1 COMPLETED - API response received in ${apiDuration.inMilliseconds}ms');
      Logger.info('🔄 CONNECTION: Stream URL: ${config.streamUrl}');

      // STAGE 2: Save configuration
      _currentConnectionStage = 'SAVING_CONFIG';
      Logger.info('🔄 CONNECTION: STAGE 2 - Saving configuration...');
      await _storageService.saveToken(token);
      await _storageService.saveLastVolume(config.volume);
      Logger.info('🔄 CONNECTION: STAGE 2 COMPLETED - Configuration saved');

      // STAGE 3: Start audio playback with detailed monitoring
      _currentConnectionStage = 'AUDIO_LOADING';
      Logger.info('🔄 CONNECTION: STAGE 3 - Starting audio playback...');
      final audioStartTime = DateTime.now();

      final playResult = await _audioService.playStream(config).timeout(
        const Duration(seconds: 25), // Timeout for audio operations
        onTimeout: () {
          final elapsed = DateTime.now().difference(audioStartTime);
          Logger.error(
              '🔄 CONNECTION: Audio playback timed out after ${elapsed.inSeconds}s');
          throw TimeoutException('Audio playback timed out');
        },
      );

      if (playResult.isFailure) {
        throw Exception('Failed to start audio: ${playResult.error}');
      }

      final audioDuration = DateTime.now().difference(audioStartTime);
      Logger.info(
          '🔄 CONNECTION: STAGE 3 COMPLETED - Audio started in ${audioDuration.inMilliseconds}ms');

      // STAGE 4: Wait for state confirmation
      _currentConnectionStage = 'WAITING_CONFIRMATION';
      Logger.info(
          '🔄 CONNECTION: STAGE 4 - Waiting for audio state confirmation...');
      await Future.delayed(const Duration(milliseconds: 500));

      _currentConnectionStage = null; // Clear stage on success
      final totalDuration = DateTime.now().difference(connectionStartTime);
      Logger.info(
          '🔄 CONNECTION: ===== CONNECTION PROCESS COMPLETED SUCCESSFULLY in ${totalDuration.inMilliseconds}ms =====');

      // State will be updated when audio starts playing via _handleAudioStateChange
    } catch (e) {
      final totalDuration = DateTime.now().difference(connectionStartTime);
      final stage = _currentConnectionStage ?? 'UNKNOWN';
      Logger.error(
          '🔄 CONNECTION: ===== CONNECTION PROCESS FAILED at stage [$stage] after ${totalDuration.inMilliseconds}ms: $e =====');
      _currentConnectionStage = null; // Clear stage on failure
      rethrow;
    }
  }

  @override
  Future<Result<void>> disconnect() async {
    return tryResultAsync(() async {
      Logger.info('Disconnecting');

      _autoReconnectEnabled = false;
      _retryTimer?.cancel();
      _configPollingTimer?.cancel();
      _stopPinging();

      await _audioService.stop();
      await _storageService.clearToken();

      _updateState(const RadioStateDisconnected(message: 'Disconnected'));

      Logger.info('Disconnected successfully');
    });
  }

  @override
  Future<Result<void>> playPause() async {
    if (!_isInitialized) {
      return const Failure('Service not initialized');
    }

    final audioState = _audioService.currentState;

    if (audioState.isPlaying) {
      return _audioService.pause();
    } else if (audioState case AudioStatePaused _) {
      return _audioService.resume();
    } else if (_currentState case RadioStateConnected connected) {
      // Restart playback
      return _audioService.playStream(connected.config);
    } else {
      return const Failure('No active connection');
    }
  }

  @override
  Future<Result<void>> setVolume(double volume) async {
    final result = await _audioService.setVolume(volume);

    // Save volume if we have a connection
    if (result.isSuccess && _currentState.isConnected) {
      await _storageService.saveLastVolume(volume);
    }

    return result;
  }

  @override
  Future<Result<void>> reconnect() async {
    final token = _getStoredToken();
    if (token == null) {
      return const Failure('No stored token available');
    }

    Logger.info('Manual reconnection requested');
    _retryManager.reset();

    return _attemptConnect(token, isRetry: true);
  }

  void _scheduleRetry(String reason) {
    if (!_autoReconnectEnabled) return;

    final token = _getStoredToken();
    if (token == null) {
      Logger.warning('Cannot retry: no stored token');
      _updateState(const RadioStateDisconnected(message: 'No token stored'));
      return;
    }

    final delay = _retryManager.getNextDelay();
    _retryManager.recordAttempt();

    Logger.info(
        'Scheduling retry in ${delay.inSeconds}s (attempt ${_retryManager.currentAttempt}, reason: $reason)');

    _updateState(RadioStateError(
      message: reason,
      canRetry: true,
      attemptCount: _retryManager.currentAttempt,
    ));

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_autoReconnectEnabled && !_isDisposed) {
        Logger.info(
            'Executing scheduled retry attempt ${_retryManager.currentAttempt + 1}');

        // Force reset any stuck connecting state before retry
        if (_currentState is RadioStateConnecting) {
          Logger.warning(
              'Forcing reset of stuck connecting state before retry');
        }

        unawaited(_attemptConnect(token, isRetry: true));
      }
    });
  }

  void _startConfigPolling() {
    _configPollingTimer?.cancel();
    _configPollingTimer = Timer.periodic(_configPollingInterval, (_) async {
      await _refreshConfig();
    });
  }

  Future<void> _refreshConfig() async {
    if (_currentState case RadioStateConnected connected) {
      try {
        final newConfig = await _apiService.getStreamConfig(connected.token);
        if (newConfig != null && newConfig != connected.config) {
          Logger.info('Configuration updated - stream URL or settings changed');

          // Only restart stream if critical parameters changed (URL, not just metadata)
          final needsRestart =
              newConfig.streamUrl != connected.config.streamUrl ||
                  newConfig.volume != connected.config.volume;

          if (needsRestart) {
            Logger.info('Stream restart required due to URL or volume change');

            // Update state with new configuration immediately
            final updatedState = connected.copyWith(config: newConfig);
            _updateState(updatedState);

            // Restart stream with new configuration
            await _audioService.stop();
            final playResult = await _audioService.playStream(newConfig);

            if (playResult.isFailure) {
              Logger.error(
                  'Failed to restart with new config: ${playResult.error}');
              _scheduleRetry('Failed to apply config update');
            }
          } else {
            Logger.info(
                'Configuration updated - metadata only, no restart needed');
            // Just update the state without restarting stream
            final updatedState = connected.copyWith(config: newConfig);
            _updateState(updatedState);
          }
        } else {
          Logger.debug('Config refresh: no changes detected');
        }
      } catch (e) {
        Logger.error('Config refresh failed: $e');
        // Don't trigger retry for config refresh failures unless audio is actually broken
        if (!_audioService.currentState.isPlaying) {
          Logger.warning(
              'Config refresh failed and audio not playing - may need retry');
          _scheduleRetry('Config refresh failed with broken audio');
        }
      }
    }
  }

  void _updateState(RadioState newState) {
    if (_currentState != newState) {
      Logger.info(
          'Radio state transition: ${_currentState.runtimeType} → ${newState.runtimeType}');

      // Track when we enter connecting state for hung detection
      if (newState is RadioStateConnecting) {
        _connectingStateStartTime = DateTime.now();
        Logger.info(
            'Entering connecting state - tracking start time for hung detection');
      } else {
        // Clear connecting time when leaving connecting state
        _connectingStateStartTime = null;
      }

      _currentState = newState;
      _stateController.add(_currentState);
    }
  }

  void _startPinging(String streamUrl) {
    _pingTimer?.cancel();

    // Extract domain from stream URL
    final uri = Uri.tryParse(streamUrl);
    if (uri == null || uri.host.isEmpty) return;

    final host = uri.host;

    // Initial ping
    _performPing(host);

    // Schedule periodic pings every 30 seconds
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _performPing(host);
    });
  }

  Future<void> _performPing(String host) async {
    try {
      final stopwatch = Stopwatch()..start();

      final socket =
          await Socket.connect(host, 80, timeout: const Duration(seconds: 10));
      await socket.close();

      stopwatch.stop();
      final pingMs = stopwatch.elapsedMilliseconds;

      _currentPing = pingMs;
      _pingController.add(pingMs);

      Logger.info('Ping to $host: ${pingMs}ms');
    } catch (e) {
      Logger.warning('Ping to $host failed: $e');
      _currentPing = null;
      _pingController.add(null);
    }
  }

  void _stopPinging() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _currentPing = null;
    _pingController.add(null);
  }

  void _startStateMonitoring() {
    _stateMonitorTimer?.cancel();

    // Monitor state every 10 seconds for hung connections
    _stateMonitorTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkForHungState();
    });

    Logger.info(
        'State monitoring started - checking every 10s for hung connections');
  }

  void _checkForHungState() {
    if (_isDisposed || !_autoReconnectEnabled) return;

    final now = DateTime.now();

    // Check if we're stuck in connecting state
    if (_currentState is RadioStateConnecting &&
        _connectingStateStartTime != null) {
      final timeInConnecting = now.difference(_connectingStateStartTime!);
      final stage = _currentConnectionStage ?? 'UNKNOWN_STAGE';

      // If stuck in connecting for more than 30 seconds, force recovery
      if (timeInConnecting.inSeconds > 30) {
        Logger.error(
            '🚨 CRITICAL: Detected hung connecting state for ${timeInConnecting.inSeconds}s at stage [$stage] - forcing recovery');
        _forceConnectionRecovery(
            'Hung connecting state detected at stage [$stage]');
        return;
      }

      // Warn if connecting too long but not yet forcing recovery
      if (timeInConnecting.inSeconds > 15) {
        Logger.warning(
            '⚠️ Connecting state prolonged: ${timeInConnecting.inSeconds}s at stage [$stage]');
      }
    }

    // Additional check: if we're in error state for too long without retry
    if (_currentState is RadioStateError) {
      final errorState = _currentState as RadioStateError;
      if (errorState.canRetry && _retryTimer == null) {
        Logger.warning(
            'Detected error state without active retry - forcing retry');
        _forceConnectionRecovery('Error state without retry detected');
      }
    }
  }

  void _forceConnectionRecovery(String reason) {
    Logger.error(
        '🔧 FORCE RECOVERY: $reason - initiating immediate reconnection');

    final token = _getStoredToken();
    if (token == null) {
      Logger.error('Cannot force recovery: no stored token');
      _updateState(
          const RadioStateDisconnected(message: 'No token for recovery'));
      return;
    }

    // Cancel all existing timers and operations
    _retryTimer?.cancel();
    _forceRecoveryTimer?.cancel();

    // Reset state tracking
    _connectingStateStartTime = null;
    _currentConnectionStage = null;
    _retryManager.reset();

    // Force immediate reconnection attempt
    Logger.info('Forcing immediate reconnection attempt...');
    unawaited(_attemptConnect(token, isRetry: true));
  }

  void _stopStateMonitoring() {
    _stateMonitorTimer?.cancel();
    _stateMonitorTimer = null;
    _forceRecoveryTimer?.cancel();
    _forceRecoveryTimer = null;
    _connectingStateStartTime = null;
    _currentConnectionStage = null;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    Logger.info('Disposing RadioService');

    _autoReconnectEnabled = false;
    _stopStateMonitoring();
    _retryTimer?.cancel();
    _configPollingTimer?.cancel();
    _stopPinging();

    await _audioStateSubscription?.cancel();
    await _networkStateSubscription?.cancel();

    await _audioService.dispose();
    await _stateController.close();
    await _pingController.close();

    Logger.info('RadioService disposed');
  }
}

/// Retry management with fixed delay
final class RetryManager {
  int _currentAttempt = 0;
  static const Duration _fixedDelay = Duration(seconds: 5);

  int get currentAttempt => _currentAttempt;

  // Always allow retry - no maximum attempts
  bool get canRetry => true;

  void recordAttempt() {
    _currentAttempt++;
  }

  void reset() {
    _currentAttempt = 0;
  }

  Duration getNextDelay() {
    // Always return fixed 5 second delay
    return _fixedDelay;
  }
}

// Extension for copying RadioStateConnected
extension RadioStateConnectedCopyWith on RadioStateConnected {
  RadioStateConnected copyWith({
    String? token,
    StreamConfig? config,
    AudioState? audioState,
    bool? isRetrying,
  }) =>
      RadioStateConnected(
        token: token ?? this.token,
        config: config ?? this.config,
        audioState: audioState ?? this.audioState,
        isRetrying: isRetrying ?? this.isRetrying,
      );
}

/// Helper to fire and forget async operations
void unawaited(Future<void> future) {
  future.catchError((error, stackTrace) {
    Logger.error('Unawaited future error: $error');
    Logger.error('Stack trace: $stackTrace');
  });
}
