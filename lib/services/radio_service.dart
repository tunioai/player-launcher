import 'dart:async';
import 'dart:io';

import '../core/result.dart';
import '../core/dependency_injection.dart';
import '../core/audio_state.dart';
import '../models/stream_config.dart';
import '../models/api_error.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/failover_service.dart';
import '../models/current_track.dart';
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
  final IFailoverService _failoverService;

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
  bool _isConnectionInProgress =
      false; // Prevent multiple simultaneous connections
  bool _isFailoverOperationInProgress =
      false; // Prevent multiple failover operations
  bool _isStreamSwitchInProgress =
      false; // Prevent failover during planned stream switches

  // Initialization
  final Completer<void> _initializationCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _isDisposed = false;

  EnhancedRadioService({
    required IAudioService audioService,
    required ApiService apiService,
    required StorageService storageService,
    required IFailoverService failoverService,
  })  : _audioService = audioService,
        _apiService = apiService,
        _storageService = storageService,
        _failoverService = failoverService;

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

  bool _isBufferChangeSignificant(AudioState newAudioState) {
    if (_currentState case RadioStateConnected connected) {
      final currentAudioState = connected.audioState;

      // Consider buffer changes significant for UI updates
      if (newAudioState is AudioStatePlaying &&
          currentAudioState is AudioStatePlaying) {
        // Update UI when buffer size changes
        return newAudioState.bufferSize != currentAudioState.bufferSize;
      }
    }
    return false;
  }

  void _handleAudioStateChange(AudioState audioState) {
    // Only log significant state changes, not position updates
    final currentType = (_currentState is RadioStateConnected)
        ? (_currentState as RadioStateConnected).audioState.runtimeType
        : null;
    final isSignificantChange = currentType != audioState.runtimeType ||
        (audioState is AudioStateError) ||
        (audioState is AudioStateLoading) ||
        _isBufferChangeSignificant(audioState);

    if (isSignificantChange) {
      Logger.info('Audio state changed: ${audioState.runtimeType}');
    }

    // Update radio state based on audio state
    switch (_currentState) {
      case RadioStateConnected connected:
        final newState = connected.copyWith(audioState: audioState);

        // Only update state if it's a significant change to avoid spam
        if (isSignificantChange ||
            connected.audioState.runtimeType != audioState.runtimeType) {
          _updateState(newState);
        } else {
          // Silently update internal state without triggering listeners
          _currentState = newState;
        }

        // Handle error states - faster detection for stream loss
        if (audioState is AudioStateError) {
          Logger.warning(
              'Audio error detected: ${audioState.message}, isRetryable: ${audioState.isRetryable}');

          // Faster detection - wait only 3 seconds for stream loss
          Timer(const Duration(seconds: 3), () {
            // Check if we're still in error state after delay
            if (_currentState is RadioStateConnected &&
                !_isConnectionInProgress) {
              final currentAudioState =
                  (_currentState as RadioStateConnected).audioState;
              if (currentAudioState is AudioStateError) {
                Logger.error(
                    'Stream lost - activating failover immediately (retryable: ${currentAudioState.isRetryable})');
                _activateFailover(
                    connected, 'Stream lost: ${currentAudioState.message}');
              } else {
                Logger.info('Audio error resolved automatically');
              }
            }
          });
        }

        // Handle unexpected stream interruption (server stop, icecast failure, etc.)
        // BUT NOT during planned stream switches
        if ((audioState is AudioStateIdle || audioState is AudioStatePaused) &&
            connected.audioState is AudioStatePlaying &&
            !_isStreamSwitchInProgress) {
          Logger.error(
              '🚨 STREAM INTERRUPTION: Stream unexpectedly stopped while we were playing');

          // Wait 2 seconds to see if it recovers automatically
          Timer(const Duration(seconds: 2), () {
            if (_currentState is RadioStateConnected &&
                !_isConnectionInProgress &&
                !_isStreamSwitchInProgress) {
              final currentAudioState =
                  (_currentState as RadioStateConnected).audioState;
              if (currentAudioState is AudioStateIdle ||
                  currentAudioState is AudioStatePaused) {
                Logger.error(
                    '🚨 STREAM INTERRUPTION: Stream still stopped, activating failover');
                _activateFailover(connected, 'Stream unexpectedly stopped');
              } else {
                Logger.info('Stream recovered automatically');
              }
            }
          });
        } else if (_isStreamSwitchInProgress) {
          Logger.info(
              '🔄 STREAM SWITCH: Audio state changed during planned stream switch, not triggering failover');
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

      case RadioStateFailover failover:
        final newState = RadioStateFailover(
          token: failover.token,
          originalConfig: failover.originalConfig,
          audioState: audioState,
          currentTrackPath: failover.currentTrackPath,
          attemptCount: failover.attemptCount,
        );

        // Only update state if it's a significant change to avoid spam
        if (isSignificantChange ||
            failover.audioState.runtimeType != audioState.runtimeType) {
          _updateState(newState);
        } else {
          // Silently update internal state without triggering listeners
          _currentState = newState;
        }

        // If track ended naturally, try to restore LIVE stream first
        if (audioState is AudioStateIdle &&
            failover.audioState is AudioStatePlaying) {
          Logger.info(
              'Failover track completed naturally, attempting to restore LIVE stream');
          _tryRestoreAfterTrackEnd(failover);
        } else if (audioState is AudioStateError && !audioState.isRetryable) {
          Logger.warning(
              'Failover track failed with non-retryable error, attempting to restore LIVE stream');
          _tryRestoreAfterTrackEnd(failover);
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

      // If we're in failover mode and network is restored, start background monitoring
      if (_currentState is RadioStateFailover) {
        Logger.info(
            '🌐 NETWORK RESTORED: Network restored during failover - starting background config monitoring');
        _startFailoverBackgroundMonitoring();
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

      // Wait a bit to ensure services are fully initialized
      await Future.delayed(const Duration(milliseconds: 500));

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
    // Prevent multiple simultaneous connection attempts
    if (_isConnectionInProgress) {
      Logger.warning(
          'Connection already in progress, skipping duplicate attempt');
      return const Success(null);
    }

    _isConnectionInProgress = true;

    final attempt = isRetry ? _retryManager.currentAttempt + 1 : 1;

    _updateState(RadioStateConnecting(
      message: isRetry ? 'Reconnecting...' : 'Connecting...',
      attempt: attempt,
    ));

    Logger.info('Attempting connection (attempt $attempt)');
    Logger.info('🐛 DEBUG: About to set up connection timeout timer');

    // Add timeout for connecting state to prevent infinite "Reconnecting"
    // Reduced to 8s for faster response on all devices including TV boxes
    final connectingTimeout = Timer(const Duration(seconds: 8), () {
      Logger.error('🐛 DEBUG: Connection timeout timer FIRED after 8 seconds');
      if (_currentState is RadioStateConnecting && _isConnectionInProgress) {
        Logger.error('Connection attempt timed out after 8 seconds');
        _isConnectionInProgress = false; // Reset connection flag
        _scheduleRetry('Connection timeout - retrying');
      } else {
        Logger.error(
            '🐛 DEBUG: Timeout fired but state changed: ${_currentState.runtimeType}, inProgress: $_isConnectionInProgress');
      }
    });

    Logger.info(
        '🐛 DEBUG: Connection timeout timer set up, about to call tryResultAsync');

    try {
      final result = await tryResultAsync(() async {
        await _performConnection(token);
      });

      connectingTimeout.cancel();
      return result;
    } catch (e) {
      connectingTimeout.cancel();
      Logger.error('Connection attempt failed: $e');

      // Schedule retry on failure
      if (_autoReconnectEnabled) {
        _scheduleRetry('Connection failed: $e');
      } else {
        _updateState(RadioStateError(
          message: 'Connection failed',
          canRetry: true,
          attemptCount: attempt,
        ));
      }

      return Failure('Connection failed: $e');
    } finally {
      _isConnectionInProgress = false;
    }
  }

  Future<void> _performConnection(String token) async {
    Logger.info('🔄 CONNECTION: ===== STARTING CONNECTION PROCESS =====');
    Logger.info(
        '🐛 DEBUG: _performConnection called with token: ${token.substring(0, 2)}****');
    final connectionStartTime = DateTime.now();

    try {
      // STAGE 1: Fetch stream configuration with timeout
      _currentConnectionStage = 'API_REQUEST';
      Logger.info('🔄 CONNECTION: STAGE 1 - Fetching stream configuration...');
      Logger.info('🐛 DEBUG: About to call _apiService.getStreamConfig()');
      final apiStartTime = DateTime.now();

      final config = await _apiService.getStreamConfig(token).timeout(
        const Duration(
            seconds: 20), // Increased to match ApiService timeout + buffer
        onTimeout: () {
          final elapsed = DateTime.now().difference(apiStartTime);
          Logger.error(
              '🔄 CONNECTION: API request timed out after ${elapsed.inSeconds}s');
          Logger.error('🐛 DEBUG: API timeout exception thrown');
          throw TimeoutException('API request timed out');
        },
      );

      Logger.info(
          '🐛 DEBUG: _apiService.getStreamConfig() completed successfully');

      if (config == null) {
        Logger.error('🐛 DEBUG: Config is null, throwing ApiError');
        throw ApiError(
            message: 'Invalid token or server error', isFromBackend: true);
      }

      Logger.info('🐛 DEBUG: Config received: ${config.streamUrl}');

      final apiDuration = DateTime.now().difference(apiStartTime);
      Logger.info(
          '🔄 CONNECTION: STAGE 1 COMPLETED - API response received in ${apiDuration.inMilliseconds}ms');
      Logger.info('🔄 CONNECTION: Stream URL: ${config.streamUrl}');

      // Download current track for failover if available
      if (config.current != null) {
        Logger.info(
            '🔄 CONNECTION: Starting background download of current track for failover');
        _downloadTrackInBackground(config.current!);
      }

      // STAGE 2: Save configuration
      _currentConnectionStage = 'SAVING_CONFIG';
      Logger.info('🔄 CONNECTION: STAGE 2 - Saving configuration...');
      await _storageService.saveToken(token);
      await _storageService.saveLastVolume(config.volume);
      Logger.info('🔄 CONNECTION: STAGE 2 COMPLETED - Configuration saved');

      // STAGE 3: Start audio playback with detailed monitoring
      _currentConnectionStage = 'AUDIO_LOADING';
      Logger.info('🔄 CONNECTION: STAGE 3 - Starting audio playback...');
      Logger.info('🐛 DEBUG: About to call _audioService.playStream()');
      final audioStartTime = DateTime.now();

      final playResult = await _audioService.playStream(config).timeout(
        const Duration(seconds: 10), // Timeout for audio operations
        onTimeout: () {
          final elapsed = DateTime.now().difference(audioStartTime);
          Logger.error(
              '🔄 CONNECTION: Audio playback timed out after ${elapsed.inSeconds}s');
          Logger.error('🐛 DEBUG: Audio playback timeout exception thrown');
          throw TimeoutException('Audio playback timed out');
        },
      );

      Logger.info(
          '🐛 DEBUG: _audioService.playStream() completed successfully');

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
      _isConnectionInProgress = false;
      _isFailoverOperationInProgress = false;
      _isStreamSwitchInProgress = false;
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

    // Don't schedule if connection is in progress
    if (_isConnectionInProgress) {
      Logger.warning('Connection in progress, skipping retry scheduling');
      return;
    }

    // Check if this is a network error and we should activate failover instead of retry
    final isNetworkError = reason.contains('No internet connection') ||
        reason.contains('Connection failed') ||
        reason.contains('Failed host lookup') ||
        reason.contains('SocketException');

    if (isNetworkError && _failoverService.cachedTracksCount > 0) {
      Logger.info(
          '🚨 NETWORK FAILOVER: Network error detected with ${_failoverService.cachedTracksCount} cached tracks - activating failover instead of retry');

      // Create a dummy connected state to use with existing failover logic
      final dummyConfig = StreamConfig(
        streamUrl: 'offline://cached',
        volume: _storageService.getLastVolume(),
      );

      final dummyConnectedState = RadioStateConnected(
        token: token,
        config: dummyConfig,
        audioState: AudioStateIdle(),
      );

      _activateFailover(dummyConnectedState, reason);
      return;
    }

    // Regular retry logic for non-network errors or when no cached tracks
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
      if (_autoReconnectEnabled && !_isDisposed && !_isConnectionInProgress) {
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

          // Download current track for failover if available
          if (newConfig.current != null) {
            _downloadTrackInBackground(newConfig.current!);
          }

          // Only restart stream if critical parameters changed (URL, not just metadata)
          final needsRestart =
              newConfig.streamUrl != connected.config.streamUrl;

          // Handle volume change separately without restarting stream
          final volumeChanged = newConfig.volume != connected.config.volume;

          if (volumeChanged) {
            Logger.info(
                'Volume changed from ${connected.config.volume} to ${newConfig.volume}');
            // Apply new volume without restarting stream
            final volumeResult =
                await _audioService.setVolume(newConfig.volume);
            if (volumeResult.isSuccess) {
              Logger.info(
                  'Successfully applied new volume: ${(newConfig.volume * 100).round()}%');
            } else {
              Logger.error('Failed to apply new volume: ${volumeResult.error}');
            }
          }

          if (needsRestart) {
            Logger.info('Stream restart required due to URL change');

            // Set flag to prevent failover during planned stream switch
            _isStreamSwitchInProgress = true;

            try {
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
              } else {
                Logger.info(
                    '✅ STREAM SWITCH: Successfully switched to new stream URL');
              }
            } finally {
              // Always clear the flag, even if there was an error
              _isStreamSwitchInProgress = false;
            }
          } else {
            Logger.info(
                'Configuration updated - ${volumeChanged ? 'volume and metadata' : 'metadata only'}, no restart needed');
            // Just update the state without restarting stream
            final updatedState = connected.copyWith(config: newConfig);
            _updateState(updatedState);
          }
        } else {
          Logger.debug('Config refresh: no changes detected');
          // Still try to download current track if we haven't done so
          if (newConfig?.current != null) {
            _downloadTrackInBackground(newConfig!.current!);
          }
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

  void _downloadTrackInBackground(CurrentTrack track) {
    // Only download music tracks for failover - skip ads, jingles, etc.
    if (!track.isMusic) {
      Logger.debug(
          'Skipping download of non-music track for failover: ${track.artist} - ${track.title}');
      return;
    }

    // Don't block the main thread with downloading
    unawaited(() async {
      try {
        await _failoverService.downloadTrack(track);
        Logger.info(
            'Successfully downloaded track for failover: ${track.artist} - ${track.title}');
      } catch (e) {
        Logger.warning('Failed to download track for failover: $e');
        // Don't throw - this is background operation
      }
    }());
  }

  void _activateFailover(RadioStateConnected connectedState, String reason) {
    if (_isFailoverOperationInProgress) {
      Logger.warning(
          '🚨 FAILOVER: Failover already in progress, ignoring duplicate request');
      return;
    }

    Logger.error('🚨 FAILOVER: Activating failover mode - $reason');
    _isFailoverOperationInProgress = true;

    // Stop current stream polling
    _configPollingTimer?.cancel();
    _stopPinging();

    unawaited(() async {
      try {
        final randomTrack = await _failoverService.getRandomTrack();
        if (randomTrack == null) {
          Logger.error('🚨 FAILOVER: No cached tracks available for failover');
          _isFailoverOperationInProgress = false;
          _scheduleRetry('No failover tracks available');
          return;
        }

        Logger.info('🚨 FAILOVER: Playing failover track: ${randomTrack.path}');

        // Switch to failover state before playing
        _updateState(RadioStateFailover(
          token: connectedState.token,
          originalConfig: connectedState.config,
          audioState:
              AudioStateLoading(config: StreamConfig(streamUrl: 'failover')),
          currentTrackPath: randomTrack.path,
          attemptCount: 0,
        ));

        // Start background monitoring for network recovery
        _startFailoverBackgroundMonitoring();

        // Play the failover track
        final playResult = await _audioService.playLocalFile(
          randomTrack.path,
          originalConfig: connectedState.config,
        );

        if (playResult.isFailure) {
          Logger.error(
              '🚨 FAILOVER: Failed to play failover track: ${playResult.error}');
          _isFailoverOperationInProgress = false;
          _scheduleRetry('Failover playback failed');
        } else {
          Logger.info('🚨 FAILOVER: Successfully started failover playback');
          _isFailoverOperationInProgress = false;
          // Don't schedule restoration here - wait for track to complete
        }
      } catch (e) {
        Logger.error('🚨 FAILOVER: Error activating failover: $e');
        _isFailoverOperationInProgress = false;
        _scheduleRetry('Failover activation failed');
      }
    }());
  }

  void _playNextFailoverTrack(RadioStateFailover failoverState) {
    if (_isFailoverOperationInProgress) {
      Logger.warning(
          '🔄 FAILOVER: Failover operation already in progress, ignoring next track request');
      return;
    }

    Logger.info('🔄 FAILOVER: Playing next random track');
    _isFailoverOperationInProgress = true;

    unawaited(() async {
      try {
        final randomTrack = await _failoverService.getRandomTrack();
        if (randomTrack == null) {
          Logger.error('🔄 FAILOVER: No more cached tracks available');
          _isFailoverOperationInProgress = false;
          _scheduleRetry('No more failover tracks');
          return;
        }

        Logger.info('🔄 FAILOVER: Playing next track: ${randomTrack.path}');

        // Update state with new track path
        _updateState(RadioStateFailover(
          token: failoverState.token,
          originalConfig: failoverState.originalConfig,
          audioState:
              AudioStateLoading(config: StreamConfig(streamUrl: 'failover')),
          currentTrackPath: randomTrack.path,
          attemptCount: failoverState.attemptCount,
        ));

        // Play the next track
        final playResult = await _audioService.playLocalFile(
          randomTrack.path,
          originalConfig: failoverState.originalConfig,
        );

        if (playResult.isFailure) {
          Logger.error(
              '🔄 FAILOVER: Failed to play next track: ${playResult.error}');
          _isFailoverOperationInProgress = false;
          // Try another track after delay
          Timer(const Duration(seconds: 3), () {
            if (_currentState is RadioStateFailover) {
              _playNextFailoverTrack(_currentState as RadioStateFailover);
            }
          });
        } else {
          Logger.info('🔄 FAILOVER: Successfully started next track');
          _isFailoverOperationInProgress = false;
        }
      } catch (e) {
        Logger.error('🔄 FAILOVER: Error playing next track: $e');
        _isFailoverOperationInProgress = false;
        Timer(const Duration(seconds: 3), () {
          if (_currentState is RadioStateFailover) {
            _playNextFailoverTrack(_currentState as RadioStateFailover);
          }
        });
      }
    }());
  }

  void _tryRestoreAfterTrackEnd(RadioStateFailover failover) {
    if (_isFailoverOperationInProgress) {
      Logger.warning(
          '🔄 RESTORE: Restore operation already in progress, ignoring duplicate request');
      return;
    }

    Logger.info(
        '🔄 RESTORE: Attempting to restore LIVE stream after failover track completion');
    _isFailoverOperationInProgress = true;

    unawaited(() async {
      try {
        // Attempt to get fresh config from server
        final config = await _apiService.getStreamConfig(failover.token);
        if (config == null) {
          Logger.warning(
              '🔄 RESTORE: Failed to get config, playing next failover track');
          _isFailoverOperationInProgress = false;
          _playNextFailoverTrack(failover);
          return;
        }

        Logger.info(
            '🔄 RESTORE: Got fresh config, attempting to restore live stream');

        // Try to play the live stream
        final playResult = await _audioService.playStream(config);
        if (playResult.isSuccess) {
          Logger.info('✅ RESTORE: Successfully restored live stream!');

          // Restore normal connected state
          _updateState(RadioStateConnected(
            token: failover.token,
            config: config,
            audioState: AudioStateLoading(config: config),
          ));

          // Resume normal operations
          _startConfigPolling();
          _startPinging(config.streamUrl);
          _isFailoverOperationInProgress = false;
        } else {
          Logger.warning(
              '🔄 RESTORE: Live stream restore failed: ${playResult.error}, playing next failover track');
          _isFailoverOperationInProgress = false;
          _playNextFailoverTrack(failover);
        }
      } catch (e) {
        Logger.error(
            '🔄 RESTORE: Error during restore attempt: $e, playing next failover track');
        _isFailoverOperationInProgress = false;
        _playNextFailoverTrackAfterDelay(failover);
      }
    }());
  }

  void _playNextFailoverTrackAfterDelay(RadioStateFailover failoverState) {
    Timer(const Duration(seconds: 3), () {
      if (_currentState is RadioStateFailover) {
        _playNextFailoverTrack(_currentState as RadioStateFailover);
      }
    });
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

    // Schedule periodic pings every 10 seconds for faster network failure detection
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
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

      // If ping fails during connected state, it might indicate network issues
      // Trigger a quick stream health check
      if (_currentState is RadioStateConnected && !_isConnectionInProgress) {
        Logger.warning(
            '🔍 PING FAIL: Ping failed during connected state - checking stream health');
        _checkStreamHealth();
      }
    }
  }

  void _stopPinging() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _currentPing = null;
    _pingController.add(null);
  }

  void _checkStreamHealth() {
    // Quick check if the stream is actually working by testing network connectivity
    unawaited(() async {
      try {
        Logger.info('🔍 STREAM HEALTH: Checking stream health...');

        // Quick network test - try to reach the API
        if (_currentState is RadioStateConnected) {
          final connected = _currentState as RadioStateConnected;

          try {
            // Quick ping to the API to test network connectivity
            final response =
                await _apiService.getStreamConfig(connected.token).timeout(
                      const Duration(seconds: 3),
                      onTimeout: () =>
                          throw TimeoutException('Health check timeout'),
                    );

            if (response == null) {
              Logger.error(
                  '🔍 STREAM HEALTH: API returned null - network issues detected');
              _activateFailover(
                  connected, 'Stream health check failed - API unreachable');
            } else {
              Logger.info('🔍 STREAM HEALTH: Network connectivity confirmed');
            }
          } catch (e) {
            Logger.error('🔍 STREAM HEALTH: Network test failed: $e');
            _activateFailover(
                connected, 'Stream health check failed - network error: $e');
          }
        }
      } catch (e) {
        Logger.error('🔍 STREAM HEALTH: Health check error: $e');

        if (_currentState is RadioStateConnected) {
          final connected = _currentState as RadioStateConnected;
          _activateFailover(connected, 'Stream health check error: $e');
        }
      }
    }());
  }

  void _startStateMonitoring() {
    _stateMonitorTimer?.cancel();

    // Monitor state every second for faster detection of hung connections
    _stateMonitorTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _checkForHungState();
    });

    Logger.info(
        'State monitoring started - checking every 1s for faster failure detection');
  }

  void _checkForHungState() {
    if (_isDisposed || !_autoReconnectEnabled) return;

    final now = DateTime.now();

    // Check if we're stuck in connecting state
    if (_currentState is RadioStateConnecting &&
        _connectingStateStartTime != null) {
      final timeInConnecting = now.difference(_connectingStateStartTime!);
      final stage = _currentConnectionStage ?? 'UNKNOWN_STAGE';

      // If stuck in connecting for more than 25 seconds, force recovery
      if (timeInConnecting.inSeconds > 25) {
        Logger.error(
            '🚨 CRITICAL: Detected hung connecting state for ${timeInConnecting.inSeconds}s at stage [$stage] - forcing recovery');
        _forceConnectionRecovery(
            'Hung connecting state detected at stage [$stage]');
        return;
      }

      // Warn if connecting too long but not yet forcing recovery
      if (timeInConnecting.inSeconds > 10) {
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

    // Don't force recovery if connection is in progress
    if (_isConnectionInProgress) {
      Logger.warning('Connection in progress, skipping force recovery');
      return;
    }

    // Cancel all existing timers and operations
    _retryTimer?.cancel();
    _forceRecoveryTimer?.cancel();

    // Reset state tracking
    _connectingStateStartTime = null;
    _currentConnectionStage = null;
    _retryManager.reset();
    _isConnectionInProgress = false; // Reset connection flag
    _isStreamSwitchInProgress = false; // Reset stream switch flag

    // Check if we should activate failover instead of forcing reconnection
    if (_failoverService.cachedTracksCount > 0) {
      Logger.info(
          '🚨 FORCE RECOVERY FAILOVER: Force recovery with ${_failoverService.cachedTracksCount} cached tracks - activating failover instead');

      // Create a dummy connected state to use with existing failover logic
      final dummyConfig = StreamConfig(
        streamUrl: 'offline://recovery',
        volume: _storageService.getLastVolume(),
      );

      final dummyConnectedState = RadioStateConnected(
        token: token,
        config: dummyConfig,
        audioState: AudioStateIdle(),
      );

      _activateFailover(
          dummyConnectedState, 'Force recovery - no internet connection');
    } else {
      // Force immediate reconnection attempt
      Logger.info('Forcing immediate reconnection attempt...');
      unawaited(_attemptConnect(token, isRetry: true));
    }
  }

  void _stopStateMonitoring() {
    _stateMonitorTimer?.cancel();
    _stateMonitorTimer = null;
    _forceRecoveryTimer?.cancel();
    _forceRecoveryTimer = null;
    _connectingStateStartTime = null;
    _currentConnectionStage = null;
  }

  Timer? _failoverBackgroundTimer;

  void _startFailoverBackgroundMonitoring() {
    _stopFailoverBackgroundMonitoring();

    Logger.info(
        '🔄 FAILOVER BACKGROUND: Starting background monitoring during failover');

    // Check every 30 seconds for config updates and new tracks while in failover
    _failoverBackgroundTimer =
        Timer.periodic(const Duration(seconds: 30), (_) async {
      if (_currentState is RadioStateFailover) {
        await _performFailoverBackgroundCheck();
      } else {
        // Stop monitoring if we're no longer in failover
        _stopFailoverBackgroundMonitoring();
      }
    });
  }

  void _stopFailoverBackgroundMonitoring() {
    _failoverBackgroundTimer?.cancel();
    _failoverBackgroundTimer = null;
  }

  Future<void> _performFailoverBackgroundCheck() async {
    if (_currentState is! RadioStateFailover) return;

    final failover = _currentState as RadioStateFailover;

    try {
      Logger.info(
          '🔄 FAILOVER BACKGROUND: Checking for config updates during failover');

      // Try to get fresh config from server
      final config = await _apiService.getStreamConfig(failover.token).timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                throw TimeoutException('Background config check timeout'),
          );

      if (config != null) {
        Logger.info(
            '🔄 FAILOVER BACKGROUND: Successfully retrieved config during failover');

        // Download current track for failover cache if available
        if (config.current != null && config.current!.isMusic) {
          Logger.info(
              '🔄 FAILOVER BACKGROUND: Downloading new track for cache: ${config.current!.artist} - ${config.current!.title}');
          _downloadTrackInBackground(config.current!);
        }

        // Update volume if changed - apply immediately during failover
        if (failover.originalConfig != null &&
            config.volume != failover.originalConfig!.volume) {
          Logger.info(
              '🔄 FAILOVER BACKGROUND: Volume changed from ${failover.originalConfig!.volume} to ${config.volume} - applying immediately');

          // Apply the new volume immediately to the current playback
          final volumeResult = await _audioService.setVolume(config.volume);
          if (volumeResult.isSuccess) {
            Logger.info(
                '🔄 FAILOVER BACKGROUND: Successfully applied new volume during failover: ${(config.volume * 100).round()}%');

            // Save the volume to storage
            await _storageService.saveLastVolume(config.volume);

            // Update the stored config with new volume
            final updatedFailover = RadioStateFailover(
              token: failover.token,
              originalConfig: config, // Update with fresh config
              audioState: failover.audioState,
              currentTrackPath: failover.currentTrackPath,
              attemptCount: failover.attemptCount,
            );
            _updateState(updatedFailover);
          } else {
            Logger.error(
                '🔄 FAILOVER BACKGROUND: Failed to apply new volume during failover: ${volumeResult.error}');
          }
        }
      } else {
        Logger.warning(
            '🔄 FAILOVER BACKGROUND: Config check returned null - network might be down again');
      }
    } catch (e) {
      Logger.warning(
          '🔄 FAILOVER BACKGROUND: Background config check failed: $e');
      // Don't stop monitoring - network might come back
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    Logger.info('Disposing RadioService');

    _autoReconnectEnabled = false;
    _isConnectionInProgress = false; // Reset connection flag
    _isFailoverOperationInProgress = false; // Reset failover flag
    _isStreamSwitchInProgress = false; // Reset stream switch flag
    _stopStateMonitoring();
    _stopFailoverBackgroundMonitoring();
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

  // Always allow retry - no maximum attempts for autonomous background operation
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
