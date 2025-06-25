import 'dart:async';
import 'dart:math';

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
  RadioState get currentState;

  Future<Result<void>> initialize();
  Future<Result<void>> connect(String token);
  Future<Result<void>> disconnect();
  Future<Result<void>> playPause();
  Future<Result<void>> setVolume(double volume);
  Future<Result<void>> reconnect();

  bool get isConnected;
  double get volume;
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

  // Subscriptions
  StreamSubscription<AudioState>? _audioStateSubscription;
  StreamSubscription<NetworkState>? _networkStateSubscription;

  // Configuration polling
  Timer? _configPollingTimer;
  static const Duration _configPollingInterval = Duration(minutes: 1);

  // Retry management
  final RetryManager _retryManager = RetryManager();
  Timer? _retryTimer;

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
  RadioState get currentState => _currentState;

  @override
  bool get isConnected => _currentState.isConnected;

  @override
  double get volume => _audioService.volume;

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
  }

  void _handleAudioStateChange(AudioState audioState) {
    Logger.info('Audio state changed: ${audioState.runtimeType}');

    // Update radio state based on audio state
    switch (_currentState) {
      case RadioStateConnected connected:
        final newState = connected.copyWith(audioState: audioState);
        _updateState(newState);

        // Handle error states
        if (audioState is AudioStateError && audioState.isRetryable) {
          _scheduleRetry('Audio error: ${audioState.message}');
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
      if (_currentState is RadioStateError ||
          _currentState is RadioStateDisconnected) {
        final token = _getStoredToken();
        if (token != null) {
          Logger.info('Network restored, attempting auto-reconnection');
          unawaited(_attemptConnect(token, isRetry: true));
        }
      }
    }
  }

  Future<void> _restoreState() async {
    final token = _getStoredToken();
    if (token != null) {
      Logger.info('Restoring connection with stored token');
      _autoReconnectEnabled = true;
      // Don't await here to avoid blocking initialization
      unawaited(_attemptConnect(token, isRetry: false));
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

    return tryResultAsync(() async {
      // Fetch stream configuration
      final config = await _apiService.getStreamConfig(token);
      if (config == null) {
        throw ApiError(
            message: 'Invalid token or server error', isFromBackend: true);
      }

      // Save token and configuration
      await _storageService.saveToken(token);
      await _storageService.saveLastVolume(config.volume);

      // Start audio playback
      final playResult = await _audioService.playStream(config);
      if (playResult.isFailure) {
        throw Exception('Failed to start audio: ${playResult.error}');
      }

      Logger.info('Connection successful');

      // State will be updated when audio starts playing via _handleAudioStateChange
    });
  }

  @override
  Future<Result<void>> disconnect() async {
    return tryResultAsync(() async {
      Logger.info('Disconnecting');

      _autoReconnectEnabled = false;
      _retryTimer?.cancel();
      _configPollingTimer?.cancel();

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
      return;
    }

    final delay = _retryManager.getNextDelay();
    _retryManager.recordAttempt();

    Logger.info('Scheduling retry in ${delay.inSeconds}s (reason: $reason)');

    _updateState(RadioStateError(
      message: reason,
      canRetry: true,
      attemptCount: _retryManager.currentAttempt,
    ));

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (_autoReconnectEnabled && !_isDisposed) {
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
          Logger.info('Configuration updated');

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
        }
      } catch (e) {
        Logger.error('Config refresh failed: $e');
        // Don't trigger retry for config refresh failures
      }
    }
  }

  void _updateState(RadioState newState) {
    if (_currentState != newState) {
      Logger.info(
          'Radio state transition: ${_currentState.runtimeType} → ${newState.runtimeType}');
      _currentState = newState;
      _stateController.add(_currentState);
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    Logger.info('Disposing RadioService');

    _autoReconnectEnabled = false;
    _retryTimer?.cancel();
    _configPollingTimer?.cancel();

    await _audioStateSubscription?.cancel();
    await _networkStateSubscription?.cancel();

    await _audioService.dispose();
    await _stateController.close();

    Logger.info('RadioService disposed');
  }
}

/// Retry management with exponential backoff
final class RetryManager {
  int _currentAttempt = 0;
  static const int _maxAttempts = 10;
  static const Duration _baseDelay = Duration(seconds: 5);
  static const Duration _maxDelay = Duration(minutes: 5);

  int get currentAttempt => _currentAttempt;

  bool get canRetry => _currentAttempt < _maxAttempts;

  void recordAttempt() {
    _currentAttempt++;
  }

  void reset() {
    _currentAttempt = 0;
  }

  Duration getNextDelay() {
    if (_currentAttempt == 0) return _baseDelay;

    // Exponential backoff with jitter
    final baseDelayMs = _baseDelay.inMilliseconds;
    final exponentialDelay = baseDelayMs * pow(2, min(_currentAttempt - 1, 5));
    final jitter = Random().nextDouble() * 0.3; // 30% jitter
    final delayMs = (exponentialDelay * (1 + jitter)).round();

    final delay = Duration(milliseconds: delayMs);
    return delay > _maxDelay ? _maxDelay : delay;
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
