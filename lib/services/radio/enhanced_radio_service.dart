import 'dart:async';
import 'dart:io';

import '../../core/audio_state.dart';
import '../../core/result.dart';
import '../../core/system_state.dart';
import '../../models/api_error.dart';
import '../../models/current_track.dart';
import '../../models/failover_event.dart';
import '../../models/stream_config.dart';
import '../../utils/logger.dart';
import '../api_service.dart';
import '../audio_service.dart';
import '../failover_reporting_service.dart';
import '../failover_service.dart';
import '../storage_service.dart';
import 'failover_recovery_backoff.dart';
import 'i_radio_service.dart';
import 'radio_state_extensions.dart';
import 'retry_manager.dart';

/// Enhanced RadioService with proper error handling and state management
final class EnhancedRadioService implements IRadioService {
  final IAudioService _audioService;
  final ApiService _apiService;
  final StorageService _storageService;
  final IFailoverService _failoverService;
  final FailoverReportingService _failoverReportingService;

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

  NetworkState _latestNetworkState =
      const NetworkState(isConnected: false, type: ConnectionType.unknown);

  // Configuration polling
  Timer? _configPollingTimer;
  static const Duration _configPollingInterval = Duration(minutes: 1);

  // Retry management
  final RetryManager _retryManager = RetryManager();
  Timer? _retryTimer;
  final FailoverRecoveryBackoff _failoverRecoveryBackoff =
      FailoverRecoveryBackoff();

  // State monitoring for hung connections - CRITICAL for device reliability
  Timer? _stateMonitorTimer;
  DateTime? _connectingStateStartTime;
  Timer? _forceRecoveryTimer;
  Timer? _networkLossTimer;
  bool _userPaused = false;
  String?
      _currentConnectionStage; // Track which stage we're in for better diagnostics
  int _consecutiveHealthFailures = 0;
  // Keep live recovery short to avoid audible gaps before fallback playback.
  static const int _healthFailureThreshold = 1;
  static const Duration _liveErrorFallbackDelayHls = Duration(seconds: 8);
  static const Duration _liveErrorFallbackDelayDefault = Duration(seconds: 4);
  static const Duration _liveInterruptionDelayHls = Duration(seconds: 6);
  static const Duration _liveInterruptionDelayDefault = Duration(seconds: 3);
  static const Duration _pingFailureGracePeriod = Duration(seconds: 6);
  static const Duration _restoreLiveAttemptTimeout = Duration(seconds: 12);
  DateTime?
      _lastFailoverRestoreTime; // Track when we last restored from failover
  DateTime?
      _lastPlayingTime; // Track when stream was last playing to prevent false failovers
  bool _isCurrentStreamHls = false;
  bool _isHlsStream(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') || lower.endsWith('.m3u');
  }

  // Auto-start and reconnection
  bool _autoReconnectEnabled = false;
  bool _isConnectionInProgress =
      false; // Prevent multiple simultaneous connections
  bool _isFailoverOperationInProgress =
      false; // Prevent multiple failover operations
  bool _isStreamSwitchInProgress =
      false; // Prevent failover during planned stream switches
  bool _hasEstablishedLiveSession = false;
  String? _pendingManualConnectToken;

  DateTime? _failoverOperationStartTime;
  String? _activeFailoverOperation;

  // Initialization
  Future<void>? _initializationFuture;
  bool _isInitialized = false;
  bool _isDisposed = false;

  EnhancedRadioService({
    required IAudioService audioService,
    required ApiService apiService,
    required StorageService storageService,
    required IFailoverService failoverService,
    required FailoverReportingService failoverReportingService,
  })  : _audioService = audioService,
        _apiService = apiService,
        _storageService = storageService,
        _failoverService = failoverService,
        _failoverReportingService = failoverReportingService;

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

    final pendingInitialization = _initializationFuture;
    if (pendingInitialization != null) {
      return tryResultAsync(() async {
        await pendingInitialization;
      });
    }

    final initialization = _performInitialization();
    _initializationFuture = initialization;

    return tryResultAsync(() async {
      await initialization;
    });
  }

  Future<void> _performInitialization() async {
    try {
      // Initialize audio service first
      final audioInitResult = await _audioService.initialize();
      if (audioInitResult.isFailure) {
        throw Exception(
            'Failed to initialize audio service: ${audioInitResult.error}');
      }

      _setupSubscriptions();
      await _restoreState();

      _isInitialized = true;
      Logger.info('RadioService: Initialized successfully');
    } finally {
      _initializationFuture = null;
    }
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

  bool get _autoLogicEnabled => !_userPaused;

  void _suspendAutoRecovery() {
    if (_userPaused) return;

    Logger.info('User pause detected - suspending auto recovery logic');
    _userPaused = true;

    _networkLossTimer?.cancel();
    _networkLossTimer = null;
    _retryTimer?.cancel();
    _forceRecoveryTimer?.cancel();

    _stopStateMonitoring();
    _stopFailoverBackgroundMonitoring();
  }

  void _resumeAutoRecovery() {
    if (!_userPaused) return;

    Logger.info('User resume detected - re-enabling auto recovery');
    _userPaused = false;

    if (_isDisposed) {
      return;
    }

    if (_currentState case RadioStateConnected(:final StreamConfig config)) {
      _startStateMonitoring();
      if (_latestNetworkState.isConnected) {
        _startPinging(config.streamUrl);
      }
    } else if (_currentState case RadioStateFailover failover) {
      _startStateMonitoring();
      if (_latestNetworkState.isConnected) {
        _startFailoverBackgroundMonitoring();
      }
      if (failover.originalConfig != null && _latestNetworkState.isConnected) {
        _startPinging(failover.originalConfig!.streamUrl);
      }
    } else {
      _startStateMonitoring();
    }
  }

  bool _isBufferChangeSignificant(AudioState newAudioState) {
    // Always propagate buffer changes for HLS so UI can display countdown.
    if (_isCurrentStreamHls && newAudioState is AudioStatePlaying) {
      return true;
    }

    // Check buffer changes for both Connected and Failover states
    if (_currentState case RadioStateConnected connected) {
      final currentAudioState = connected.audioState;
      if (newAudioState is AudioStatePlaying &&
          currentAudioState is AudioStatePlaying) {
        return newAudioState.bufferSize != currentAudioState.bufferSize;
      }
    } else if (_currentState case RadioStateFailover failover) {
      final currentAudioState = failover.audioState;
      if (newAudioState is AudioStatePlaying &&
          currentAudioState is AudioStatePlaying) {
        // For failover, only consider buffer changes significant if they're substantial
        final bufferDiff = (newAudioState.bufferSize.inSeconds -
                currentAudioState.bufferSize.inSeconds)
            .abs();
        return bufferDiff >
            2; // Only update if buffer changed by more than 2 seconds
      }
    }
    return false;
  }

  void _handleAudioStateChange(AudioState audioState) {
    // Only log significant state changes, not position updates
    final currentType = switch (_currentState) {
      RadioStateConnected(:final AudioState audioState) =>
        audioState.runtimeType,
      RadioStateFailover(:final AudioState audioState) =>
        audioState.runtimeType,
      _ => null,
    };
    final shouldLogStateChange = currentType != audioState.runtimeType ||
        (audioState is AudioStateError) ||
        (audioState is AudioStateLoading);
    final shouldUpdateState =
        shouldLogStateChange || _isBufferChangeSignificant(audioState);

    if (shouldLogStateChange) {
      Logger.info('Audio state changed: ${audioState.runtimeType}');
    }

    if (audioState.isPlaying) {
      _resetHealthFailures();
    }

    // Update radio state based on audio state
    switch (_currentState) {
      case RadioStateConnected connected:
        final newState = connected.copyWith(audioState: audioState);
        _isCurrentStreamHls = _isHlsStream(connected.config.streamUrl);

        // Only update state if it's a significant change to avoid spam
        if (shouldUpdateState ||
            connected.audioState.runtimeType != audioState.runtimeType) {
          _updateState(newState);

          // If we successfully restored from failover, log it
          if (connected.audioState is AudioStateLoading &&
              audioState.isPlaying) {
            Logger.info(
                '✅ RESTORE: Live stream is now playing after restore from failover');
            Logger.info(
                '✅ RESTORE: State updated from AudioStateLoading to AudioStatePlaying');
          }
        } else {
          // Silently update internal state without triggering listeners
          _currentState = newState;
        }

        // Track when stream is playing to prevent false failovers
        if (audioState.isPlaying) {
          _markLiveSessionEstablished();
          _lastPlayingTime = DateTime.now();
        }

        if (!_autoLogicEnabled) {
          return;
        }

        // Handle error states - faster detection for stream loss
        if (audioState is AudioStateError) {
          final fallbackDelay = _isCurrentStreamHls
              ? _liveErrorFallbackDelayHls
              : _liveErrorFallbackDelayDefault;
          Logger.warning(
              'Audio error detected: ${audioState.message}, isRetryable: ${audioState.isRetryable}');

          // Check if this is a network error and we should activate failover immediately
          final isNetworkError =
              audioState.message.contains('No internet connection') ||
                  audioState.message.contains('Connection failed') ||
                  audioState.message.contains('Failed host lookup') ||
                  audioState.message.contains('SocketException') ||
                  audioState.message.contains('Network error') ||
                  audioState.message.contains('Connection timeout');

          if (isNetworkError) {
            Logger.info(
                '⚠️ NETWORK ERROR: Attempting restart before failover (${audioState.message})');
            unawaited(() async {
              if (_currentState is! RadioStateConnected) return;
              final latest = _currentState as RadioStateConnected;
              final restarted = await _attemptStreamRestart(
                  latest, 'Network error: ${audioState.message}');
              if (restarted) {
                Logger.info('Network error resolved by restart');
                return;
              }

              if (_failoverService.cachedTracksCount > 0) {
                _activateFailover(
                    latest, 'Network error: ${audioState.message}');
              } else {
                Logger.warning(
                    'Network error but no failover tracks available - staying in error state');
              }
            }());
            return;
          }

          // Wait longer on HLS since playlist can recover on its own
          Timer(fallbackDelay, () {
            if (_currentState is! RadioStateConnected ||
                _isConnectionInProgress ||
                _isStreamSwitchInProgress) {
              return;
            }

            final latest = _currentState as RadioStateConnected;
            final currentAudioState = latest.audioState;

            // ✅ CRITICAL: Check if stream is actually playing before failover
            if (_audioService.currentState.isPlaying) {
              Logger.info(
                  'Stream is actually playing, ignoring error state - no failover needed');
              return;
            }

            if (currentAudioState is AudioStateError) {
              Logger.warning(
                  'Stream still in error after delay, attempting restart');
              unawaited(() async {
                final restarted = await _attemptStreamRestart(
                    latest, 'Retry after audio error');
                if (restarted) {
                  Logger.info('Stream recovered after retry');
                  return;
                }

                Logger.error(
                    'Stream restart failed after error delay - activating failover');
                _activateFailover(
                    latest, 'Stream lost: ${currentAudioState.message}');
              }());
            } else {
              Logger.info('Audio error resolved automatically');
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

          final interruptionDelay = _isCurrentStreamHls
              ? _liveInterruptionDelayHls
              : _liveInterruptionDelayDefault;

          // Wait longer for HLS playlists to catch up
          Timer(interruptionDelay, () {
            if (_currentState is! RadioStateConnected ||
                _isConnectionInProgress ||
                _isStreamSwitchInProgress) {
              return;
            }

            final latest = _currentState as RadioStateConnected;
            final currentAudioState = latest.audioState;

            // ✅ CRITICAL: Check if stream is actually playing before failover
            if (_audioService.currentState.isPlaying) {
              Logger.info(
                  'Stream is actually playing, ignoring idle state - no failover needed');
              return;
            }

            if (currentAudioState is AudioStateIdle ||
                currentAudioState is AudioStatePaused) {
              Logger.warning(
                  'Stream still idle after interruption - attempting restart');
              unawaited(() async {
                final restarted = await _attemptStreamRestart(
                    latest, 'Unexpected idle state');
                if (restarted) {
                  Logger.info('Stream recovered after idle restart');
                  return;
                }

                Logger.error(
                    'Stream restart failed after idle detection - activating failover');
                _activateFailover(latest, 'Stream unexpectedly stopped');
              }());
            } else {
              Logger.info('Stream recovered automatically');
            }
          });
        } else if (_isStreamSwitchInProgress) {
          Logger.info(
              '🔄 STREAM SWITCH: Audio state changed during planned stream switch, not triggering failover');
        }

      case RadioStateConnecting connecting:
        // Check if we successfully started playing
        if (audioState.isPlaying) {
          _markLiveSessionEstablished();
          // We should have config at this point
          final config = audioState.config;
          final token = connecting.token ?? _getStoredToken();
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
        break;

      case RadioStateFailover failover:
        final newState = RadioStateFailover(
          token: failover.token,
          originalConfig: failover.originalConfig,
          audioState: audioState,
          currentTrackPath: failover.currentTrackPath,
          attemptCount: failover.attemptCount,
        );

        // Only update state if it's a significant change to avoid spam
        if (shouldUpdateState ||
            failover.audioState.runtimeType != audioState.runtimeType) {
          _updateState(newState);

          // Log only significant failover state changes
          if (shouldLogStateChange) {
            Logger.info(
                '🚨 FAILOVER: Audio state changed to ${audioState.runtimeType}');
          }
        } else {
          // Silently update internal state without triggering listeners
          _currentState = newState;
        }

        if (audioState is AudioStateIdle &&
            (failover.audioState is AudioStatePlaying ||
                failover.audioState is AudioStatePaused)) {
          if (!_autoLogicEnabled) {
            return;
          }
          Logger.info(
              '🚨 FAILOVER_DEBUG: Failover track completed naturally (${failover.audioState.runtimeType} → Idle)');
          Logger.info(
              '🚨 FAILOVER_DEBUG: Waiting 2s to confirm track end before restore attempt...');

          Timer(const Duration(seconds: 2), () {
            if (_currentState is RadioStateFailover) {
              final currentFailover = _currentState as RadioStateFailover;
              if (currentFailover.audioState is AudioStateIdle) {
                Logger.info(
                    '🚨 FAILOVER_DEBUG: Track end confirmed, attempting to restore LIVE stream');
                _tryRestoreAfterTrackEnd(currentFailover);
              } else {
                Logger.info(
                    '🚨 FAILOVER_DEBUG: False track end - still playing, ignoring');
              }
            }
          });
        } else if (audioState is AudioStateError && !audioState.isRetryable) {
          if (!_autoLogicEnabled) {
            return;
          }
          Logger.warning(
              '🚨 FAILOVER_DEBUG: Failover track failed with non-retryable error, attempting to restore LIVE stream');
          _tryRestoreAfterTrackEnd(failover);
        }
      // Removed spammy logging: No restore needed

      default:
        // Other states don't need audio state updates
        break;
    }
  }

  void _handleNetworkStateChange(NetworkState networkState) {
    Logger.info('Network state changed: connected=${networkState.isConnected}');
    _latestNetworkState = networkState;

    if (!networkState.isConnected) {
      if (_autoLogicEnabled) {
        _handleNetworkLoss();
      } else {
        Logger.info(
            'Network lost but auto recovery is suspended due to user pause');
      }
      return;
    }

    _networkLossTimer?.cancel();
    _networkLossTimer = null;

    if (!_autoLogicEnabled) {
      return;
    }

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
          unawaited(_failoverReportingService.flush(pin: token));
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

  void _handleNetworkLoss() {
    // Avoid spamming timers if network toggles rapidly
    if (_networkLossTimer != null) {
      return;
    }

    if (!_autoLogicEnabled) {
      Logger.info(
          'Ignoring network loss failover trigger - auto recovery suspended');
      return;
    }

    if (!_autoReconnectEnabled) {
      return;
    }

    if (_currentState is! RadioStateConnected) {
      Logger.info(
          'Network lost but radio state is ${_currentState.runtimeType}, skipping immediate failover');
      return;
    }

    if (_failoverService.cachedTracksCount == 0) {
      Logger.warning(
          'Network lost but no cached tracks available for failover');
      return;
    }

    Logger.warning(
        '🌐 NETWORK LOSS: Connectivity lost - scheduling quick failover');
    Duration dynamicDelay = const Duration(seconds: 3);
    if (_isCurrentStreamHls) {
      final bufferedAhead = _extractBufferedAhead(_audioService.currentState);
      final cappedBuffer = bufferedAhead > const Duration(seconds: 60)
          ? const Duration(seconds: 60)
          : bufferedAhead;
      dynamicDelay = const Duration(seconds: 6) + cappedBuffer;
      Logger.info(
          '🌐 NETWORK LOSS: HLS stream has ${bufferedAhead.inSeconds}s buffered - deferring failover timer by ${dynamicDelay.inSeconds}s');
    }

    final lossDelay = dynamicDelay;

    _networkLossTimer = Timer(lossDelay, () {
      _networkLossTimer = null;

      if (_latestNetworkState.isConnected) {
        Logger.info(
            '🌐 NETWORK LOSS: Network restored before failover timer fired');
        return;
      }

      if (_currentState is! RadioStateConnected) {
        Logger.info(
            '🌐 NETWORK LOSS: State changed from connected before timer fired');
        return;
      }

      if (_isCurrentStreamHls) {
        Logger.warning(
            '🌐 NETWORK LOSS: HLS stream detected - giving playlist recovery extra time');
        Timer(const Duration(seconds: 5), () {
          if (_latestNetworkState.isConnected ||
              _currentState is! RadioStateConnected) {
            Logger.info(
                '🌐 NETWORK LOSS: Recovery detected during extended wait');
            return;
          }
          Logger.error(
              '🚨 NETWORK LOSS: Triggering failover due to sustained connectivity loss (HLS)');
          final connected = _currentState as RadioStateConnected;
          _activateFailover(connected, 'Network connection lost (HLS)');
        });
        return;
      }

      Logger.error(
          '🚨 NETWORK LOSS: Triggering failover due to sustained connectivity loss');
      final connected = _currentState as RadioStateConnected;
      _activateFailover(connected, 'Network connection lost');
    });
  }

  Duration _extractBufferedAhead(AudioState state) {
    return switch (state) {
      AudioStatePlaying(:final bufferSize) => bufferSize,
      AudioStateBuffering(:final bufferSize) => bufferSize,
      AudioStatePaused(:final bufferSize) => bufferSize,
      _ => Duration.zero,
    };
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
            unawaited(_scheduleRetry('Auto-reconnect failed on startup'));
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
    _resumeAutoRecovery();

    return _attemptConnect(token, isRetry: false);
  }

  Future<Result<void>> _attemptConnect(String token,
      {required bool isRetry}) async {
    // Prevent multiple simultaneous connection attempts
    if (_isConnectionInProgress) {
      if (!isRetry) {
        final activeToken = _currentState is RadioStateConnecting
            ? (_currentState as RadioStateConnecting).token
            : null;
        if (activeToken == token) {
          Logger.warning(
              'Manual connect requested while connection is in progress (same token) - ignoring duplicate request');
          return const Success(null);
        }

        _pendingManualConnectToken = token;
        Logger.warning(
            'Manual connect requested while connection is in progress - queued request will run after current attempt completes');
        return const Success(null);
      } else {
        Logger.warning(
            'Connection already in progress, skipping duplicate attempt');
        return const Success(null);
      }
    }

    _isConnectionInProgress = true;
    _isStreamSwitchInProgress = true;

    final attempt = isRetry ? _retryManager.currentAttempt + 1 : 1;

    _updateState(RadioStateConnecting(
      message: isRetry ? 'Reconnecting...' : 'Connecting...',
      attempt: attempt,
      token: token,
    ));

    // Make sure any existing stream is stopped before starting a new one.
    // When stream URLs change quickly some platforms keep the old HTTP
    // connection around in a half-open state which shows up as “ghost”
    // listeners on the Icecast server. Explicitly stop playback and timers
    // so the transport is torn down before we begin another connection.
    await _prepareForFreshConnection(isRetry: isRetry);

    Logger.info('Attempting connection (attempt $attempt)');

    // Keep this above the per-stage timeouts (API + playStream) so it doesn't
    // prematurely abort a slow but valid connection attempt (notably HLS on
    // macOS in --release).
    final connectingTimeout = Timer(const Duration(seconds: 70), () {
      if (_currentState is RadioStateConnecting && _isConnectionInProgress) {
        Logger.error('Connection attempt timed out after 70 seconds');
        _isConnectionInProgress = false;
        unawaited(_scheduleRetry('Connection timeout - retrying'));
      }
    });

    try {
      final result = await tryResultAsync(() async {
        await _performConnection(token);
      });

      connectingTimeout.cancel();
      if (result.isFailure) {
        final failure = result as Failure<void>;
        final errorMessage = failure.message;
        final exception = failure.exception;
        final apiError = exception is ApiError ? exception : null;
        final isInvalidToken = apiError != null &&
            apiError.isFromBackend &&
            (apiError.statusCode == 401 ||
                errorMessage.toLowerCase().contains('invalid'));

        if (isInvalidToken) {
          _autoReconnectEnabled = false;
          _updateState(RadioStateError(
            message: errorMessage,
            canRetry: false,
            attemptCount: attempt,
          ));
        } else if (_autoReconnectEnabled) {
          _isConnectionInProgress = false;
          unawaited(_scheduleRetry('Connection failed: $errorMessage'));
        } else {
          _updateState(RadioStateError(
            message: 'Connection failed',
            canRetry: true,
            attemptCount: attempt,
          ));
        }
      }
      return result;
    } catch (e) {
      connectingTimeout.cancel();
      Logger.error('Connection attempt failed: $e');

      // Schedule retry on failure
      if (_autoReconnectEnabled) {
        _isConnectionInProgress = false;
        unawaited(_scheduleRetry('Connection failed: $e'));
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
      _isStreamSwitchInProgress = false;

      final pendingToken = _pendingManualConnectToken;
      if (pendingToken != null && !_isDisposed) {
        _pendingManualConnectToken = null;
        unawaited(_attemptConnect(pendingToken, isRetry: false));
      }
    }
  }

  Future<void> _prepareForFreshConnection({required bool isRetry}) async {
    final audioState = _audioService.currentState;
    final hasActiveAudio = audioState.isPlaying ||
        audioState is AudioStateLoading ||
        audioState is AudioStateBuffering;
    final hadRadioSession = _currentState.isConnected ||
        _currentState is RadioStateFailover ||
        _currentState is RadioStateConnecting;

    if (!hasActiveAudio && !hadRadioSession) {
      return;
    }

    final contextLabel = isRetry ? 'retry' : 'manual connect';
    Logger.info(
        'Preparing fresh $contextLabel attempt - stopping existing playback and timers');

    _configPollingTimer?.cancel();
    _stopPinging();
    _stopFailoverBackgroundMonitoring();

    final stopResult = await _audioService.stop();
    if (stopResult.isFailure) {
      Logger.warning(
          'Failed to stop playback before $contextLabel: ${stopResult.error}');
    }
  }

  Future<void> _performConnection(String token) async {
    Logger.info('🔄 CONNECTION: ===== STARTING CONNECTION PROCESS =====');
    Logger.info(
        '🐛 DEBUG: _performConnection called with token: ${token.substring(0, 2)}****');
    final connectionStartTime = DateTime.now();

    try {
      final previousToken = _storageService.getToken();
      final tokenChanged = previousToken != null &&
          previousToken.isNotEmpty &&
          previousToken != token;

      // STAGE 1: Fetch stream configuration with timeout
      _currentConnectionStage = 'API_REQUEST';
      Logger.info('🔄 CONNECTION: STAGE 1 - Fetching stream configuration...');
      Logger.info('🐛 DEBUG: About to call _apiService.getStreamConfig()');
      final apiStartTime = DateTime.now();

      final config = await _apiService
          .getStreamConfig(token, currentPing: _currentPing)
          .timeout(
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

      // STAGE 2: Save configuration
      _currentConnectionStage = 'SAVING_CONFIG';
      Logger.info('🔄 CONNECTION: STAGE 2 - Saving configuration...');
      await _storageService.saveToken(token);
      await _storageService.saveLastVolume(config.failoverVolume);
      Logger.info('🔄 CONNECTION: STAGE 2 COMPLETED - Configuration saved');

      // STAGE 3: Start audio playback with detailed monitoring
      _currentConnectionStage = 'AUDIO_LOADING';
      Logger.info('🔄 CONNECTION: STAGE 3 - Starting audio playback...');
      Logger.info('🐛 DEBUG: About to call _audioService.playStream()');
      final audioStartTime = DateTime.now();

      final playResult = await _audioService.playStream(config).timeout(
        const Duration(
            seconds:
                35), // Increased from 30s to 35s to let internal timeout with player check complete first
        onTimeout: () {
          final elapsed = DateTime.now().difference(audioStartTime);

          // Check if actually playing despite timeout
          if (_audioService.currentState.isPlaying) {
            Logger.warning(
                '🔄 CONNECTION: External playStream timeout after ${elapsed.inSeconds}s BUT audio is actually playing - ignoring timeout');
            return Success(null);
          }

          Logger.error(
              '🔄 CONNECTION: Audio playback timed out after ${elapsed.inSeconds}s and NOT playing');
          Logger.error('🐛 DEBUG: Audio playback timeout exception thrown');
          throw TimeoutException('Audio playback timed out');
        },
      );

      Logger.info(
          '🐛 DEBUG: _audioService.playStream() completed successfully');

      if (playResult.isFailure) {
        // Check if audio is actually playing despite the failure
        final currentAudioState = _audioService.currentState;
        if (currentAudioState.isPlaying) {
          Logger.warning(
              '🔄 CONNECTION: playStream returned failure but audio is playing - ignoring timeout error');
          Logger.warning('🔄 CONNECTION: Error was: ${playResult.error}');
        } else {
          throw Exception('Failed to start audio: ${playResult.error}');
        }
      }

      final audioDuration = DateTime.now().difference(audioStartTime);
      Logger.info(
          '🔄 CONNECTION: STAGE 3 COMPLETED - Audio started in ${audioDuration.inMilliseconds}ms');

      if (tokenChanged) {
        Logger.info(
            '🧹 CLEANUP: PIN changed - clearing failover cache to avoid mixing stations');
        // Wait for the cache to clear so subsequent downloads belong only to
        // the newly selected station.
        await _failoverService.clearCache();
      }

      // Download current track for failover (after any cache reset).
      if (config.current != null) {
        Logger.info(
            '🔄 CONNECTION: Starting background download of current track for failover');
        _downloadTrackInBackground(config.current!);
      }

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
      final result = await _audioService.pause();
      if (result.isSuccess) {
        _suspendAutoRecovery();
      }
      return result;
    } else if (audioState case AudioStatePaused _) {
      _resumeAutoRecovery();
      final result = await _audioService.resume();
      if (result.isFailure) {
        _suspendAutoRecovery();
      }
      return result;
    } else if (_currentState case RadioStateConnected connected) {
      _resumeAutoRecovery();
      final result =
          await _audioService.playStream(connected.config, quickStart: true);
      if (result.isFailure) {
        _suspendAutoRecovery();
      }
      return result;
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
    _resumeAutoRecovery();

    return _attemptConnect(token, isRetry: true);
  }

  Future<void> _scheduleRetry(String reason) async {
    if (!_autoReconnectEnabled) return;

    final token = _getStoredToken();
    if (token == null) {
      Logger.warning('Cannot retry: no stored token');
      _updateState(const RadioStateDisconnected(message: 'No token stored'));
      return;
    }

    if (_isConnectionInProgress) {
      Logger.warning('Connection in progress, skipping retry scheduling');
      return;
    }

    if (!_autoLogicEnabled) {
      Logger.info(
          'Skipping retry scheduling because auto recovery is suspended');
      return;
    }

    if (_currentState is RadioStateFailover) {
      final failover = _currentState as RadioStateFailover;
      if (failover.audioState.isPlaying) {
        Logger.info(
            'Failover is playing successfully, ignoring retry request: $reason');
        return;
      }
    }

    // Try to reliably close the previous stream before establishing a new connection
    final stopResult = await _audioService.stop();
    if (stopResult.isFailure) {
      Logger.warning(
          'Retry scheduler: stop before retry failed: ${stopResult.error}');
      return;
    }

    // Check if this is a network error and we should activate failover instead of retry
    final isNetworkError = reason.contains('No internet connection') ||
        reason.contains('Failed host lookup') ||
        reason.contains('SocketException') ||
        reason.contains('Network error') ||
        reason.contains('Connection timeout');

    final shouldDeferStartupFailover = isNetworkError &&
        _failoverService.cachedTracksCount > 0 &&
        !_hasEstablishedLiveSession &&
        _retryManager.currentAttempt == 0 &&
        _currentState is RadioStateConnecting;

    if (shouldDeferStartupFailover) {
      Logger.info(
          'Startup connection failed before first successful live playback - scheduling retry before failover');
    }

    if (isNetworkError &&
        _failoverService.cachedTracksCount > 0 &&
        !shouldDeferStartupFailover) {
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

  void _markLiveSessionEstablished() {
    if (_hasEstablishedLiveSession) {
      return;
    }
    _hasEstablishedLiveSession = true;
    Logger.info('Live stream playback confirmed for current app session');
  }

  void _startConfigPolling() {
    _configPollingTimer?.cancel();
    _configPollingTimer = Timer.periodic(_configPollingInterval, (_) async {
      await _refreshConfig();
    });
  }

  Future<void> _refreshConfig() async {
    if (_currentState case RadioStateConnected connected) {
      if (!_autoLogicEnabled) {
        Logger.debug('Config refresh skipped - auto recovery suspended');
        return;
      }

      try {
        // Run API call in background to prevent blocking audio thread
        Logger.debug('Starting background config refresh...');

        final newConfig = await Future(() async {
          // This ensures the API call runs asynchronously
          return await _apiService.getStreamConfig(connected.token,
              currentPing: _currentPing);
        });

        if (newConfig != null && newConfig != connected.config) {
          Logger.info('Configuration updated - stream URL or settings changed');

          final stationChanged = newConfig.streamUuid != null &&
              connected.config.streamUuid != null &&
              newConfig.streamUuid != connected.config.streamUuid;

          // Download current track for failover if available
          if (newConfig.current != null) {
            _downloadTrackInBackground(newConfig.current!);
          }

          // Only restart stream if critical parameters changed (URL, not just metadata)
          final needsRestart =
              newConfig.streamUrl != connected.config.streamUrl;

          // Handle volume change separately without restarting stream
          final failoverVolumeChanged =
              newConfig.failoverVolume != connected.config.failoverVolume;
          final masterVolumeChanged =
              newConfig.volume != connected.config.volume;

          if (failoverVolumeChanged) {
            Logger.info(
                'Failover volume changed from ${connected.config.failoverVolume} to ${newConfig.failoverVolume}');
            await _storageService.saveLastVolume(newConfig.failoverVolume);
          }

          if (masterVolumeChanged && _autoLogicEnabled) {
            final targetVolume = newConfig.volume.clamp(0.0, 1.0);
            Logger.info(
                'Master volume changed from ${connected.config.volume} to $targetVolume - applying to audio player');
            final result = await _audioService.setVolume(targetVolume);
            if (result.isFailure) {
              Logger.error(
                  'Failed to apply updated master volume: ${result.error}');
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
                unawaited(_scheduleRetry('Failed to apply config update'));
              } else {
                Logger.info(
                    '✅ STREAM SWITCH: Successfully switched to new stream URL');
                Logger.info(
                    '🧹 CLEANUP: Stream URL switched successfully, clearing failover cache');
                unawaited(_failoverService.clearCache());
              }
            } finally {
              // Always clear the flag, even if there was an error
              _isStreamSwitchInProgress = false;
            }
          } else {
            Logger.info(
                'Configuration updated - ${failoverVolumeChanged ? 'failover volume and metadata' : 'metadata only'}, no restart needed');
            // Just update the state without restarting stream
            final updatedState = connected.copyWith(config: newConfig);
            _updateState(updatedState);

            if (stationChanged) {
              Logger.info(
                  '🧹 CLEANUP: Station changed (stream_uuid), clearing failover cache');
              unawaited(_failoverService.clearCache());
            }
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
          unawaited(_scheduleRetry('Config refresh failed with broken audio'));
        }
      }
    }
  }

  double _resolveFailoverVolume(StreamConfig? config) {
    if (config != null) {
      final resolved = config.failoverVolume;
      if (!resolved.isNaN) {
        return resolved.clamp(0.0, 1.0);
      }
    }

    final stored = _storageService.getLastVolume();
    return stored.clamp(0.0, 1.0);
  }

  Future<double?> _applyFailoverVolume(StreamConfig? config,
      {bool persist = false}) async {
    final targetVolume = _resolveFailoverVolume(config);
    Logger.info('🎵 FAILOVER: Applying failover volume: $targetVolume');

    final result = await _audioService.setVolume(targetVolume);
    if (result.isFailure) {
      Logger.error(
          '🎵 FAILOVER: Failed to apply failover volume: ${result.error}');
      return null;
    }

    if (persist) {
      await _storageService.saveLastVolume(targetVolume);
    }

    return targetVolume;
  }

  void _downloadTrackInBackground(CurrentTrack track) {
    // Only download music tracks for failover - skip ads, jingles, etc.
    if (!track.isMusic) {
      Logger.info(
          'Failover download skipped (non-music): ${track.artist} - ${track.title}');
      return;
    }

    // Don't block the main thread with downloading
    unawaited(() async {
      try {
        Logger.info(
            'Failover download queued: ${track.artist} - ${track.title} (${track.uuid})');
        await _failoverService.downloadTrack(track);
        Logger.info(
            'Successfully downloaded track for failover: ${track.artist} - ${track.title}');
      } catch (e) {
        Logger.warning('Failed to download track for failover: $e');
        // Don't throw - this is background operation
      }
    }());
  }

  void _resetHealthFailures() {
    if (_consecutiveHealthFailures != 0) {
      Logger.debug('Health check failures reset', 'RadioService');
    }
    _consecutiveHealthFailures = 0;
  }

  void _recordFailoverEvent({
    required FailoverEventDirection direction,
    required String reason,
    String? pin,
    Map<String, dynamic>? extra,
  }) {
    final data = <String, dynamic>{
      'audioState': _audioService.currentState.runtimeType.toString(),
      'pingMs': _currentPing,
      'retryAttempt': _retryManager.currentAttempt,
      if (extra != null) ...extra,
    };

    final event = FailoverEvent.create(
      direction: direction,
      reason: reason,
      extra: data,
    );

    unawaited(_failoverReportingService.logEvent(event, pin: pin));
  }

  Future<bool> _attemptStreamRestart(
    RadioStateConnected connected,
    String reason,
  ) async {
    if (!_autoLogicEnabled) {
      Logger.info(
          'Skipping live stream restart ($reason) - auto recovery suspended');
      return false;
    }

    if (_isConnectionInProgress) {
      Logger.warning(
          'Skipping stream restart ($reason) - connection already in progress');
      return false;
    }

    Logger.info('Attempting live stream restart: $reason');
    _isConnectionInProgress = true;
    _isStreamSwitchInProgress = true;

    try {
      final stopResult = await _audioService.stop();
      if (stopResult.isFailure) {
        Logger.warning(
            'Stop before restart failed: ${stopResult.error}', 'RadioService');
      }
      final result =
          await _audioService.playStream(connected.config, quickStart: true);
      if (result.isSuccess) {
        Logger.info('Live stream restart succeeded: $reason');
        _resetHealthFailures();
        return true;
      }

      Logger.warning('Live stream restart failed: $reason → ${result.error}',
          'RadioService');
      return false;
    } catch (e) {
      Logger.error('Live stream restart threw error: $e', 'RadioService');
      return false;
    } finally {
      _isStreamSwitchInProgress = false;
      _isConnectionInProgress = false;
    }
  }

  Future<void> _handleHealthCheckFailure(
    RadioStateConnected connected,
    String reason,
  ) async {
    if (!_autoLogicEnabled) {
      Logger.info('Health check failure ignored - auto recovery suspended');
      return;
    }

    // Give live stream time to stabilize after restore from failover
    if (_lastFailoverRestoreTime != null) {
      final timeSinceRestore =
          DateTime.now().difference(_lastFailoverRestoreTime!);
      if (timeSinceRestore.inSeconds < 60) {
        // Increased from 30s to 60s
        Logger.info(
            'Health check failure ignored - within 60s grace period after failover restore');
        return;
      }
    }

    // ✅ Additional protection: if stream was recently playing, give more time
    if (_lastPlayingTime != null) {
      final timeSincePlaying = DateTime.now().difference(_lastPlayingTime!);
      if (timeSincePlaying.inSeconds < 30) {
        Logger.info(
            'Health check failure ignored - stream was playing recently (${timeSincePlaying.inSeconds}s ago)');
        return;
      }
    }

    _consecutiveHealthFailures++;
    Logger.warning(
        'Health check failure #$_consecutiveHealthFailures: $reason');

    if (_consecutiveHealthFailures < _healthFailureThreshold) {
      return;
    }

    Logger.error('Health check threshold reached - attempting stream restart');
    final restarted =
        await _attemptStreamRestart(connected, 'Health check failure');
    if (restarted) {
      return;
    }

    Logger.error('Health check restart failed - activating failover');
    _activateFailover(connected, 'Stream health check failed: $reason');
  }

  void _startFailoverOperation(
    String operation,
    Future<void> Function() action,
  ) {
    _isFailoverOperationInProgress = true;
    _failoverOperationStartTime = DateTime.now();
    _activeFailoverOperation = operation;

    unawaited(() async {
      try {
        await action();
      } catch (e, stackTrace) {
        Logger.error('🚨 FAILOVER: Unhandled error during $operation: $e',
            'RadioService');
        Logger.error('$stackTrace', 'RadioService');
      } finally {
        _releaseFailoverOperationLock();
      }
    }());
  }

  void _releaseFailoverOperationLock() {
    if (_isFailoverOperationInProgress) {
      Logger.debug(
          '🚨 FAILOVER: Releasing operation lock (${_activeFailoverOperation ?? 'unknown'})');
    }

    _isFailoverOperationInProgress = false;
    _failoverOperationStartTime = null;
    _activeFailoverOperation = null;
  }

  void _activateFailover(RadioStateConnected connectedState, String reason) {
    if (_isFailoverOperationInProgress) {
      Logger.warning(
          '🚨 FAILOVER: Failover already in progress, ignoring duplicate request');
      return;
    }

    if (!_autoLogicEnabled) {
      Logger.info(
          '🚨 FAILOVER: Activation skipped because auto recovery is suspended');
      return;
    }

    if (_currentState is RadioStateFailover) {
      final failover = _currentState as RadioStateFailover;
      if (failover.audioState.isPlaying) {
        Logger.info(
            '🚨 FAILOVER: Already in failover and playing, ignoring activation request');
        return;
      }
    }

    Logger.error('🚨 FAILOVER: Activating failover mode - $reason');

    final now = DateTime.now();
    final recentRestoreAge = _lastFailoverRestoreTime != null
        ? now.difference(_lastFailoverRestoreTime!)
        : null;
    final wasRecentRestore = recentRestoreAge != null &&
        recentRestoreAge <= FailoverRecoveryBackoff.recentRestoreThreshold;

    _failoverRecoveryBackoff.recordFailoverActivation(
        wasRecentRestore: wasRecentRestore);
    if (wasRecentRestore) {
      Logger.warning(
          '🚨 FAILOVER: Stream failed ${recentRestoreAge.inSeconds}s after last restore - applying restore backoff');
    }
    _logRestoreDelayPlan('Failover activation');

    _recordFailoverEvent(
      direction: FailoverEventDirection.failover,
      reason: reason,
      pin: connectedState.token,
      extra: {
        'cachedTracks': _failoverService.cachedTracksCount,
        'audioState': connectedState.audioState.runtimeType.toString(),
      },
    );
    _resetHealthFailures();

    // Stop current stream polling
    _configPollingTimer?.cancel();
    _stopPinging();

    _startFailoverOperation('activate', () async {
      try {
        final randomTrack = await _failoverService.getRandomTrack();
        if (randomTrack == null) {
          Logger.error('🚨 FAILOVER: No cached tracks available for failover');
          _releaseFailoverOperationLock();
          unawaited(_scheduleRetry('No failover tracks available'));
          return;
        }

        Logger.info('🚨 FAILOVER: Playing failover track: ${randomTrack.path}');

        await _applyFailoverVolume(connectedState.config);

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
          _releaseFailoverOperationLock();
          unawaited(_scheduleRetry('Failover playback failed'));
          return;
        }

        Logger.info('🚨 FAILOVER: Successfully started failover playback');
        // Don't schedule restoration here - wait for track to complete
      } catch (e) {
        Logger.error('🚨 FAILOVER: Error activating failover: $e');
        _releaseFailoverOperationLock();
        unawaited(_scheduleRetry('Failover activation failed'));
      }
    });
  }

  void _playNextFailoverTrack(RadioStateFailover failoverState) {
    if (!_autoLogicEnabled) {
      Logger.info('🔄 FAILOVER: Skipping next track - auto recovery suspended');
      return;
    }

    if (_isFailoverOperationInProgress) {
      Logger.warning(
          '🔄 FAILOVER: Failover operation already in progress, ignoring next track request');
      return;
    }

    Logger.info('🔄 FAILOVER: Playing next random track');
    _startFailoverOperation('next_track', () async {
      try {
        final randomTrack = await _failoverService.getRandomTrack();
        if (randomTrack == null) {
          Logger.error('🔄 FAILOVER: No more cached tracks available');
          _releaseFailoverOperationLock();
          unawaited(_scheduleRetry('No more failover tracks'));
          return;
        }

        Logger.info('🔄 FAILOVER: Playing next track: ${randomTrack.path}');

        await _applyFailoverVolume(failoverState.originalConfig);

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
          _releaseFailoverOperationLock();
          // Try another track after delay
          Timer(const Duration(seconds: 1), () {
            if (_currentState is RadioStateFailover) {
              _playNextFailoverTrack(_currentState as RadioStateFailover);
            }
          });
          return;
        }

        Logger.info('🔄 FAILOVER: Successfully started next track');
      } catch (e) {
        Logger.error('🔄 FAILOVER: Error playing next track: $e');
        _releaseFailoverOperationLock();
        Timer(const Duration(seconds: 1), () {
          if (_currentState is RadioStateFailover) {
            _playNextFailoverTrack(_currentState as RadioStateFailover);
          }
        });
      }
    });
  }

  void _tryRestoreAfterTrackEnd(RadioStateFailover failover) {
    if (!_autoLogicEnabled) {
      Logger.info(
          '🔄 RESTORE: Skipping auto-restore - auto recovery suspended');
      return;
    }

    if (SystemState.instance.offlineMode) {
      Logger.info(
          '🔄 RESTORE: Offline mode enabled - skipping restore and continuing failover playback');
      _playNextFailoverTrack(failover);
      return;
    }

    if (_isFailoverOperationInProgress) {
      Logger.warning(
          '🔄 RESTORE: Restore operation already in progress, ignoring duplicate request');
      return;
    }

    final pendingSkipBefore = _failoverRecoveryBackoff.consumePendingSkip();
    if (pendingSkipBefore != null) {
      final remainingAfter = pendingSkipBefore - 1;
      final remainingTracks = remainingAfter < 0 ? 0 : remainingAfter;
      Logger.warning(
          '🔄 RESTORE: Delaying restore attempt due to unstable connection (level ${_failoverRecoveryBackoff.instabilityLevel}) - '
          '$remainingTracks more failover track(s) before next attempt');
      _playNextFailoverTrack(failover);
      return;
    }

    Logger.info(
        '🔄 RESTORE: ===== STARTING RESTORE PROCESS AFTER TRACK END =====');
    Logger.info(
        '🔄 RESTORE: Attempting to restore LIVE stream after failover track completion');
    Logger.info('🔄 RESTORE: Failover token: ${failover.token}');
    _startFailoverOperation('restore', () async {
      try {
        final isNetworkReportedOffline = !_latestNetworkState.isConnected;
        final configTimeout = isNetworkReportedOffline
            ? const Duration(seconds: 2)
            : const Duration(seconds: 5);
        final restoreTimeout = isNetworkReportedOffline
            ? const Duration(seconds: 4)
            : _restoreLiveAttemptTimeout;
        if (isNetworkReportedOffline) {
          Logger.warning(
              '🔄 RESTORE: Network is reported offline, running a quick restore probe to avoid getting stuck in failover');
        }

        // Attempt to get fresh config from server with a short timeout
        final config = await _apiService
            .getStreamConfig(failover.token, currentPing: _currentPing)
            .timeout(
              configTimeout,
              onTimeout: () => throw TimeoutException(
                  'Config request timeout', configTimeout),
            );
        if (config == null) {
          Logger.warning(
              '🔄 RESTORE: Failed to get config, playing next failover track');
          _failoverRecoveryBackoff.recordRestoreFailure();
          _logRestoreDelayPlan('Config fetch failed');
          _releaseFailoverOperationLock();
          _playNextFailoverTrack(failover);
          return;
        }

        Logger.info(
            '🔄 RESTORE: Got fresh config, attempting to restore live stream');

        await _storageService.saveLastVolume(config.failoverVolume);

        // Try to restore live stream quickly to avoid long silent gaps.
        final playResult =
            await _audioService.playStream(config, quickStart: true).timeout(
                  restoreTimeout,
                  onTimeout: () =>
                      const Failure('Restore live stream attempt timed out'),
                );
        if (playResult.isSuccess) {
          Logger.info('✅ RESTORE: Successfully restored live stream!');
          _resetHealthFailures();
          _lastFailoverRestoreTime =
              DateTime.now(); // Mark restore time for grace period
          _failoverRecoveryBackoff.recordSuccessfulRestore();
          Logger.info(
              '🔄 RESTORE BACKOFF: Resetting restore delay after successful recovery');

          _recordFailoverEvent(
            direction: FailoverEventDirection.restore,
            reason: 'live stream restored',
            pin: failover.token,
            extra: {
              'failoverAttempts': failover.attemptCount,
            },
          );

          // Restore normal connected state
          Logger.info(
              '✅ RESTORE: Changing state from RadioStateFailover to RadioStateConnected');
          _updateState(RadioStateConnected(
            token: failover.token,
            config: config,
            audioState: AudioStateLoading(config: config),
          ));
          Logger.info(
              '✅ RESTORE: State changed to RadioStateConnected, UI should update now');

          // Resume normal operations
          _startConfigPolling();
          _startPinging(config.streamUrl);
          _startStateMonitoring(); // Restart state monitoring after restore
          _lastFailoverRestoreTime =
              DateTime.now(); // Mark restore time for grace period
        } else {
          Logger.warning(
              '🔄 RESTORE: Live stream restore failed: ${playResult.error}, playing next failover track');
          _failoverRecoveryBackoff.recordRestoreFailure();
          _logRestoreDelayPlan('Live stream playback failed');
          _releaseFailoverOperationLock();
          _playNextFailoverTrack(failover);
        }
      } catch (e) {
        Logger.error(
            '🔄 RESTORE: Error during restore attempt: $e, playing next failover track');
        _failoverRecoveryBackoff.recordRestoreFailure();
        _logRestoreDelayPlan('Restore threw error');
        _releaseFailoverOperationLock();
        _playNextFailoverTrackAfterDelay(failover,
            delay: const Duration(seconds: 1));
      }
    });
  }

  void _playNextFailoverTrackAfterDelay(RadioStateFailover failoverState,
      {Duration delay = const Duration(seconds: 1)}) {
    if (!_autoLogicEnabled) {
      Logger.info(
          '🔄 FAILOVER: Skipping delayed next track - auto recovery suspended');
      return;
    }

    Timer(delay, () {
      if (_currentState is RadioStateFailover) {
        _playNextFailoverTrack(_currentState as RadioStateFailover);
      }
    });
  }

  void _logRestoreDelayPlan(String reason) {
    final pendingTracks = _failoverRecoveryBackoff.pendingTrackSkips;
    if (pendingTracks <= 0) {
      return;
    }
    Logger.warning(
        '🔄 RESTORE BACKOFF: $reason - waiting for $pendingTracks failover track(s) before the next live stream attempt');
  }

  void _updateState(RadioState newState) {
    if (_currentState != newState) {
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

    // Schedule periodic pings every 30 seconds to reduce load
    _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _performPing(host);
    });
  }

  Future<void> _performPing(String host) async {
    // Run ping in background to prevent blocking audio thread
    unawaited(Future(() async {
      if (!_autoLogicEnabled) {
        Logger.debug('Ping skipped - auto recovery suspended');
        return;
      }

      try {
        final stopwatch = Stopwatch()..start();

        final socket = await Socket.connect(host, 80,
            timeout: const Duration(seconds: 5) // Reduced timeout to 5s
            );
        await socket.close();

        stopwatch.stop();
        final pingMs = stopwatch.elapsedMilliseconds;

        _currentPing = pingMs;
        _pingController.add(pingMs);

        Logger.debug('Ping to $host: ${pingMs}ms'); // Reduced to debug level
      } catch (e) {
        Logger.debug('Ping to $host failed: $e'); // Reduced to debug level
        _currentPing = null;
        _pingController.add(null);

        // If ping fails during connected state, it might indicate network issues
        // But don't trigger health check too aggressively from ping failures
        if (_currentState is RadioStateConnected &&
            !_isConnectionInProgress &&
            !_audioService.currentState.isPlaying &&
            _autoLogicEnabled) {
          // ✅ Give more time for stream to start playing after ping failure
          Timer(_pingFailureGracePeriod, () {
            if (_currentState is RadioStateConnected &&
                !_audioService.currentState.isPlaying &&
                !_isConnectionInProgress &&
                _autoLogicEnabled) {
              Logger.warning(
                  '🔍 PING FAIL: Ping failed and audio still not playing after ${_pingFailureGracePeriod.inSeconds}s - checking stream health');
              _checkStreamHealth();
            }
          });
        }
      }
    }));
  }

  void _stopPinging() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _currentPing = null;
    _pingController.add(null);
  }

  void _checkStreamHealth() {
    if (_currentState is! RadioStateConnected) {
      return;
    }

    if (!_autoLogicEnabled) {
      Logger.debug(
          '🔍 STREAM HEALTH: Auto recovery suspended - skipping health check');
      return;
    }

    if (_audioService.currentState.isPlaying) {
      _resetHealthFailures();
      _lastPlayingTime = DateTime.now(); // Track last playing time
      return;
    }

    final connected = _currentState as RadioStateConnected;

    unawaited(() async {
      try {
        Logger.info('🔍 STREAM HEALTH: Checking stream health...');
        final response = await _apiService
            .getStreamConfig(connected.token, currentPing: _currentPing)
            .timeout(const Duration(seconds: 5));

        if (response != null) {
          Logger.info('🔍 STREAM HEALTH: Connectivity confirmed');
          _resetHealthFailures();
          return;
        }

        await _handleHealthCheckFailure(connected, 'Config response empty');
      } on TimeoutException catch (e) {
        Logger.warning('🔍 STREAM HEALTH: Timeout: $e');
        await _handleHealthCheckFailure(connected, 'Timeout');
      } on ApiError catch (e) {
        Logger.warning('🔍 STREAM HEALTH: API error: ${e.message}');
        await _handleHealthCheckFailure(connected, e.message);
      } catch (e) {
        Logger.error('🔍 STREAM HEALTH: Unexpected error: $e');
        await _handleHealthCheckFailure(connected, e.toString());
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

    if (!_autoLogicEnabled) {
      return;
    }

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

    if (_isFailoverOperationInProgress &&
        _failoverOperationStartTime != null &&
        _activeFailoverOperation != null) {
      final elapsed = now.difference(_failoverOperationStartTime!);

      if (elapsed.inSeconds > 60) {
        Logger.error(
            '🚨 FAILOVER: Operation ${_activeFailoverOperation!} stuck for ${elapsed.inSeconds}s - releasing lock');
        _releaseFailoverOperationLock();
      } else if (elapsed.inSeconds > 30) {
        Logger.warning(
            '⚠️ FAILOVER: Operation ${_activeFailoverOperation!} running for ${elapsed.inSeconds}s');
      }
    }
  }

  void _forceConnectionRecovery(String reason) {
    Logger.error(
        '🔧 FORCE RECOVERY: $reason - initiating immediate reconnection');

    if (!_autoLogicEnabled) {
      Logger.info('🔧 FORCE RECOVERY: Skipping - auto recovery suspended');
      return;
    }

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
    if (!_autoLogicEnabled) {
      Logger.info(
          '🔄 FAILOVER BACKGROUND: Not starting - auto recovery suspended');
      return;
    }

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

    if (!_autoLogicEnabled) {
      Logger.info(
          '🔄 FAILOVER BACKGROUND: Skipping background check - auto recovery suspended');
      return;
    }

    final failover = _currentState as RadioStateFailover;

    try {
      Logger.info(
          '🔄 FAILOVER BACKGROUND: Checking for config updates during failover');

      // Try to get fresh config from server
      final config = await _apiService
          .getStreamConfig(failover.token, currentPing: _currentPing)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                throw TimeoutException('Background config check timeout'),
          );

      if (config != null) {
        Logger.info(
            '🔄 FAILOVER BACKGROUND: Successfully retrieved config during failover');

        await _storageService.saveLastVolume(config.failoverVolume);

        // Download current track for failover cache if available
        if (config.current != null && config.current!.isMusic) {
          Logger.info(
              '🔄 FAILOVER BACKGROUND: Downloading new track for cache: ${config.current!.artist} - ${config.current!.title}');
          _downloadTrackInBackground(config.current!);
        }

        // Update volume if changed - apply immediately during failover
        if (failover.originalConfig != null &&
            config.failoverVolume != failover.originalConfig!.failoverVolume) {
          Logger.info(
              '🔄 FAILOVER BACKGROUND: Failover volume changed from ${failover.originalConfig!.failoverVolume} to ${config.failoverVolume} - applying immediately');

          final appliedVolume =
              await _applyFailoverVolume(config, persist: true);

          if (appliedVolume != null) {
            Logger.info(
                '🔄 FAILOVER BACKGROUND: Successfully applied new failover volume: ${(appliedVolume * 100).round()}%');

            // Update the stored config with new volume
            final updatedFailover = RadioStateFailover(
              token: failover.token,
              originalConfig: config, // Update with fresh config
              audioState: failover.audioState,
              currentTrackPath: failover.currentTrackPath,
              attemptCount: failover.attemptCount,
            );
            _updateState(updatedFailover);
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
    _networkLossTimer?.cancel();
    _networkLossTimer = null;

    await _audioStateSubscription?.cancel();
    await _networkStateSubscription?.cancel();

    await _audioService.dispose();
    await _stateController.close();
    await _pingController.close();

    Logger.info('RadioService disposed');
  }
}

/// Helper to fire and forget async operations
void unawaited(Future<void> future) {
  future.catchError((error, stackTrace) {
    Logger.error('Unawaited future error: $error');
    Logger.error('Stack trace: $stackTrace');
  });
}
