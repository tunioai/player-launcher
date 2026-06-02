import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/result.dart';
import '../core/dependency_injection.dart';
import '../core/audio_state.dart';
import '../models/stream_config.dart';
import '../utils/logger.dart';
import '../utils/audio_config.dart';
import 'audio/hls_stream_audio_source.dart';

abstract interface class IAudioService implements Disposable {
  Stream<AudioState> get stateStream;
  Stream<NetworkState> get networkStream;
  AudioState get currentState;

  Future<Result<void>> initialize();
  Future<Result<void>> playStream(StreamConfig config,
      {bool quickStart = false});
  Future<Result<void>> playLocalFile(String filePath,
      {StreamConfig? originalConfig});
  Future<Result<void>> pause();
  Future<Result<void>> resume();
  Future<Result<void>> stop();
  Future<Result<void>> setVolume(double volume);

  double get volume;
}

final class EnhancedAudioService implements IAudioService {
  late AudioPlayer _audioPlayer;

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<NetworkState> _networkController =
      StreamController<NetworkState>.broadcast();

  AudioState _currentState = const AudioStateIdle();
  NetworkState _networkState =
      const NetworkState(isConnected: false, type: ConnectionType.unknown);

  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _bufferSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;

  StreamConfig? _currentConfig;

  double _currentVolume = 1.0;

  PlaybackStats _playbackStats = const PlaybackStats();
  DateTime? _streamStartTime;
  DateTime? _lastBufferUpdate;
  Duration _currentBufferSize = Duration.zero;

  // Ghost playback detection for live streams
  Duration _lastBufferSize = Duration.zero;
  int _stuckBufferCount = 0;

  // Playback-progress stall detection. Catches the "silent" stall where the
  // player still reports playing=true but the position stops advancing (flaky
  // network on TVs: connectivity_plus stays online and the source never
  // surfaces an error). Position progress is the only reliable signal here.
  Duration _lastProgressPosition = Duration.zero;
  DateTime? _lastProgressAt;

  Timer? _loadingTimeoutTimer;
  Timer? _hangDetectionTimer;
  Future<void>? _initializationFuture;
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _isPlayingStream = false;
  bool _isPlayStreamInProgress = false; // Prevent concurrent playStream calls
  String? _currentStreamUrl;
  bool _userPaused = false;
  bool _awaitingInterruptionResume = false;
  bool _connectivityInitialized = false;
  bool _isCurrentLoadConfigurationHls = false;
  HlsStreamAudioSource? _activeHlsSource;
  Duration? _currentHlsPlaylistWindow;
  Duration _lastRawHlsBuffer = Duration.zero;
  Duration _lastPlaybackPosition = Duration.zero;
  Duration _hlsBufferedDuration = Duration.zero;

  static const Duration _loadingTimeout = Duration(seconds: 10);
  static const Duration _hangDetectionInterval = Duration(seconds: 5);
  static const Duration _maxHangTime = Duration(seconds: 20);
  static const Duration _bufferStallThreshold = Duration(seconds: 20);
  // How long playback position may stay frozen (while playing=true) before we
  // treat it as a stalled stream and trigger recovery.
  static const Duration _playbackStallTimeout = Duration(seconds: 10);
  static const Duration _playbackStallTimeoutHls = Duration(seconds: 12);

  @override
  Stream<AudioState> get stateStream => _stateController.stream;

  @override
  Stream<NetworkState> get networkStream => _networkController.stream;

  @override
  AudioState get currentState => _currentState;

  @override
  double get volume => _currentVolume;

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
      await _initializeAudioPlayer();
      _setupSubscriptions();
      _startHangDetection();

      _isInitialized = true;
      Logger.info('AudioService: Initialized successfully');
    } finally {
      _initializationFuture = null;
    }
  }

  bool _isHlsStream(String url) {
    final uri = Uri.parse(url);
    final path = uri.path.toLowerCase();
    return path.endsWith('.m3u8') ||
        path.contains('.m3u8?') ||
        path.endsWith('.m3u') ||
        url.contains('playlist.m3u8');
  }

  Future<void> _initializeAudioPlayer({bool isHls = false}) async {
    Logger.info('🎵 INIT_DEBUG: ===== INITIALIZING AUDIO PLAYER =====');
    Logger.info('🎵 INIT_DEBUG: User agent: ${AudioConfig.userAgent}');

    _audioPlayer = AudioPlayer(
      userAgent: AudioConfig.userAgent,
      audioLoadConfiguration: AudioConfig.buildLoadConfiguration(isHls: isHls),
      useProxyForRequestHeaders: false,
    );
    _isCurrentLoadConfigurationHls = isHls;

    if (!Platform.isWindows) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy:
            AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ));

      _observeAudioSessionInterruptions(session);
      Logger.info('🎵 INIT_DEBUG: Audio session configured');
    } else {
      Logger.info('🎵 INIT_DEBUG: Audio session skipped on Windows');
    }

    Logger.info('🎵 INIT_DEBUG: AudioPlayer instance created');
    Logger.info('🎵 INIT_DEBUG: ===== AUDIO PLAYER INITIALIZED =====');
  }

  void _setupSubscriptions() {
    _setupPlayerSubscriptions();
    _setupConnectivitySubscription();
  }

  void _setupPlayerSubscriptions() {
    _playerStateSubscription?.cancel();
    _playerStateSubscription = _audioPlayer.playerStateStream.listen(
      _handlePlayerStateChange,
      onError: _handlePlayerError,
    );

    // CRITICAL: Listen to playbackEventStream to catch native ExoPlayer errors
    // that don't propagate through playerStateStream
    _playbackEventSubscription?.cancel();
    _playbackEventSubscription = _audioPlayer.playbackEventStream.listen(
      (event) {
        // Check for errors in playback event
        if (event.processingState == ProcessingState.idle &&
            _audioPlayer.playing &&
            _currentConfig != null) {
          Logger.error(
              '🚨 CRITICAL: PlaybackEvent shows IDLE but player.playing=true - native error detected!');
          Logger.error('🚨 CRITICAL: Event: $event');
          _handlePlayerError(Exception(
              'Native playback error detected - processingState=idle while playing'));
        }
      },
      onError: (error, stackTrace) {
        Logger.error(
            '🚨 CRITICAL: PlaybackEvent stream error (native ExoPlayer error): $error');
        Logger.error('🚨 CRITICAL: Stack trace: $stackTrace');
        _handlePlayerError(error);
      },
    );

    _positionSubscription?.cancel();
    _positionSubscription = _audioPlayer.positionStream.listen(
      _handlePositionUpdate,
      onError: (error) => Logger.error('Position stream error: $error'),
    );

    _bufferSubscription?.cancel();
    _bufferSubscription = _audioPlayer.bufferedPositionStream.listen(
      _handleBufferUpdate,
      onError: (error) => Logger.error('Buffer stream error: $error'),
    );

    _currentIndexSubscription?.cancel();
    _currentIndexSubscription = _audioPlayer.currentIndexStream.listen(
      (index) {
        if (index == null && _currentConfig != null) {
          Logger.info('Track completed - transitioning to idle');
          _currentState = const AudioStateIdle();
          _stateController.add(_currentState);
        }
      },
      onError: (error) => Logger.error('Current index stream error: $error'),
    );
  }

  void _setupConnectivitySubscription() {
    if (_connectivityInitialized) {
      return;
    }

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
          _handleConnectivityChange,
          onError: (error) => Logger.error('Connectivity stream error: $error'),
        );

    _connectivityInitialized = true;
    _checkInitialNetworkState();
  }

  Future<void> _cancelPlayerSubscriptions() async {
    await _playerStateSubscription?.cancel();
    _playerStateSubscription = null;

    await _playbackEventSubscription?.cancel();
    _playbackEventSubscription = null;

    await _positionSubscription?.cancel();
    _positionSubscription = null;

    await _bufferSubscription?.cancel();
    _bufferSubscription = null;

    await _currentIndexSubscription?.cancel();
    _currentIndexSubscription = null;

    await _interruptionSubscription?.cancel();
    _interruptionSubscription = null;
  }

  Future<void> _resetAudioPlayer(String reason, {bool? isHlsOverride}) async {
    if (_isDisposed) return;

    Logger.warning('🎵 AUDIO_DEBUG: Recreating AudioPlayer due to: $reason');

    await _cancelPlayerSubscriptions();
    await _disposeActiveHlsSource();

    try {
      await _audioPlayer.dispose();
      Logger.info('🎵 AUDIO_DEBUG: Old AudioPlayer disposed successfully');
    } catch (e, stackTrace) {
      Logger.error(
          '🎵 AUDIO_DEBUG: Failed to dispose AudioPlayer during reset: $e');
      Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
    }

    final isHls = isHlsOverride ?? _isCurrentLoadConfigurationHls;
    await _initializeAudioPlayer(isHls: isHls);
    _setupPlayerSubscriptions();

    try {
      await _audioPlayer.setVolume(_currentVolume);
      Logger.info('🎵 AUDIO_DEBUG: Restored audio volume to $_currentVolume');
    } catch (e, stackTrace) {
      Logger.error(
          '🎵 AUDIO_DEBUG: Failed to restore volume after player reset: $e');
      Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
    }
  }

  Future<void> _stopPlayerSafely(String reason,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (_isDisposed) {
      return;
    }

    try {
      await _audioPlayer.stop().timeout(timeout);
    } on TimeoutException {
      Logger.error(
          '🎵 AUDIO_DEBUG: stop() timed out after ${timeout.inSeconds}s ($reason)');
      await _resetAudioPlayer('stop timeout while $reason');
    } catch (e, stackTrace) {
      Logger.error('🎵 AUDIO_DEBUG: stop() threw while $reason: $e');
      Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
      await _resetAudioPlayer('stop error while $reason');
    }
  }

  void _observeAudioSessionInterruptions(AudioSession session) {
    _interruptionSubscription?.cancel();
    _interruptionSubscription = session.interruptionEventStream.listen(
      (event) async {
        if (_isDisposed) return;

        if (event.begin) {
          _awaitingInterruptionResume = true;
          Logger.info('🎧 AUDIO_SESSION: Interruption began (${event.type})');
          if (_audioPlayer.playing &&
              (event.type == AudioInterruptionType.pause ||
                  event.type == AudioInterruptionType.unknown)) {
            try {
              await _audioPlayer.pause();
              Logger.info(
                  '🎧 AUDIO_SESSION: Paused playback due to interruption');
            } catch (e, stackTrace) {
              Logger.error(
                  '🎧 AUDIO_SESSION: Failed to pause during interruption: $e');
              Logger.error('🎧 AUDIO_SESSION: $stackTrace');
            }
          }
        } else {
          Logger.info('🎧 AUDIO_SESSION: Interruption ended (${event.type})');
          if (_awaitingInterruptionResume && !_userPaused) {
            _awaitingInterruptionResume = false;
            try {
              await session.setActive(true);
              if (!_audioPlayer.playing) {
                await _audioPlayer.play();
                Logger.info(
                    '🎧 AUDIO_SESSION: Playback resumed after interruption');
              }
            } catch (e, stackTrace) {
              Logger.error(
                  '🎧 AUDIO_SESSION: Failed to resume after interruption: $e');
              Logger.error('🎧 AUDIO_SESSION: $stackTrace');
              _handlePlayerError(
                  Exception('Resume after interruption failed: $e'));
            }
          } else {
            _awaitingInterruptionResume = false;
          }
        }
      },
      onError: (error, stackTrace) {
        Logger.error('🎧 AUDIO_SESSION: Interruption stream error: $error');
        Logger.error('🎧 AUDIO_SESSION: $stackTrace');
      },
    );
  }

  Future<void> _checkInitialNetworkState() async {
    try {
      await Future.delayed(const Duration(milliseconds: 500));
      final results = await Connectivity().checkConnectivity();

      final hasInternet = await _testInternetConnectivity();

      final hasConnection = results.any((result) =>
              result == ConnectivityResult.mobile ||
              result == ConnectivityResult.wifi ||
              result == ConnectivityResult.ethernet) &&
          hasInternet;

      final connectionType = switch (results.firstOrNull) {
        ConnectivityResult.wifi => ConnectionType.wifi,
        ConnectivityResult.mobile => ConnectionType.mobile,
        ConnectivityResult.ethernet => ConnectionType.ethernet,
        _ => ConnectionType.unknown,
      };

      _networkState = _networkState.copyWith(
        isConnected: hasConnection,
        type: connectionType,
      );
      _networkController.add(_networkState);

      Logger.info(
          'Initial network state: ${hasConnection ? 'Connected' : 'Disconnected'} (${connectionType.displayName})');
    } catch (e) {
      Logger.error('Failed to check initial network state: $e');
      _networkState = _networkState.copyWith(
        isConnected: true,
        type: ConnectionType.unknown,
      );
      _networkController.add(_networkState);
    }
  }

  Future<bool> _testInternetConnectivity() async {
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (e) {
      Logger.warning('Internet connectivity test failed: $e');
      return true;
    }
  }

  void _handlePlayerStateChange(PlayerState playerState) {
    Logger.info('🎵 STATE_DEBUG: ===== PLAYER STATE CHANGED =====');
    Logger.info('🎵 STATE_DEBUG: Playing: ${playerState.playing}');
    Logger.info(
        '🎵 STATE_DEBUG: Processing state: ${playerState.processingState}');
    Logger.info('🎵 STATE_DEBUG: Player position: ${_audioPlayer.position}');

    if (playerState.processingState == ProcessingState.buffering &&
        !playerState.playing) {
      _currentBufferSize = Duration.zero;
      _lastRawHlsBuffer = Duration.zero;
    }

    final newAudioState = _computeAudioState(playerState);
    Logger.info(
        '🎵 STATE_DEBUG: Computed new audio state: ${newAudioState.runtimeType}');

    if (_currentState.runtimeType != newAudioState.runtimeType) {
      Logger.info(
          '🎵 STATE_DEBUG: Audio state transition: ${_currentState.runtimeType} → ${newAudioState.runtimeType}');

      switch (newAudioState) {
        case AudioStateLoading():
          Logger.info('🎵 STATE_DEBUG: Starting loading timeout...');
          _startLoadingTimeout();

        case AudioStatePlaying():
          Logger.info(
              '🎵 STATE_DEBUG: Canceling timeouts and updating stats...');
          _cancelTimeouts();
          _updatePlaybackStats();

          if (!_networkState.isConnected) {
            Logger.info(
                '🎵 STATE_DEBUG: Correcting network state - we are playing, so we must be connected');
            _networkState = _networkState.copyWith(isConnected: true);
            _networkController.add(_networkState);
          }

        case AudioStateError():
          Logger.info('🎵 STATE_DEBUG: Canceling timeouts due to error...');
          _cancelTimeouts();

        default:
          Logger.info(
              '🎵 STATE_DEBUG: No special handling for state: ${newAudioState.runtimeType}');
          break;
      }
    } else {
      Logger.info(
          '🎵 STATE_DEBUG: State type unchanged: ${_currentState.runtimeType}');
    }

    _currentState = newAudioState;
    _stateController.add(_currentState);
    Logger.info('🎵 STATE_DEBUG: State updated and emitted');
  }

  AudioState _computeAudioState(PlayerState playerState) {
    if (_currentConfig == null) return const AudioStateIdle();

    final position = _audioPlayer.position;
    final processingState = playerState.processingState;
    final isPlaying = playerState.playing;

    if (isPlaying) {
      if (processingState == ProcessingState.ready ||
          processingState == ProcessingState.buffering) {
        return AudioStatePlaying(
          config: _currentConfig!,
          position: position,
          bufferSize: _currentBufferSize,
          stats: _playbackStats,
        );
      }
    }

    if (processingState == ProcessingState.loading) {
      return AudioStateLoading(
        config: _currentConfig!,
        elapsed: _getElapsedTime(),
      );
    }

    if (processingState == ProcessingState.buffering) {
      return AudioStateBuffering(
        config: _currentConfig!,
        bufferSize: _currentBufferSize,
        elapsed: _getElapsedTime(),
      );
    }

    if (processingState == ProcessingState.completed) {
      return const AudioStateIdle();
    }

    if (!isPlaying && position.inMilliseconds > 0) {
      return AudioStatePaused(
        config: _currentConfig!,
        position: position,
        bufferSize: _currentBufferSize,
      );
    }

    return AudioStateLoading(
      config: _currentConfig!,
      elapsed: _getElapsedTime(),
    );
  }

  Duration _getElapsedTime() {
    if (_streamStartTime == null) return Duration.zero;
    return DateTime.now().difference(_streamStartTime!);
  }

  void _handlePositionUpdate(Duration position) {
    if (_currentState is AudioStatePlaying) {
      final delta = position - _lastPlaybackPosition;
      if (_isCurrentLoadConfigurationHls &&
          delta > Duration.zero &&
          _currentBufferSize > Duration.zero) {
        final remaining = _currentBufferSize - delta;
        _currentBufferSize = remaining.isNegative ? Duration.zero : remaining;
        _hlsBufferedDuration = _currentBufferSize;
        final newRaw = _lastRawHlsBuffer - delta;
        _lastRawHlsBuffer = newRaw.isNegative ? Duration.zero : newRaw;
      }
      _lastPlaybackPosition = position;

      final playing = _currentState as AudioStatePlaying;
      _currentState = playing.copyWith(
        position: position,
        bufferSize: _currentBufferSize,
      );
      _stateController.add(_currentState);
    }
  }

  void _handleBufferUpdate(Duration? bufferedPosition) {
    if (bufferedPosition == null) return;

    final currentPosition = _audioPlayer.position;
    final rawBufferAhead = bufferedPosition - currentPosition;

    final isHls = _currentStreamUrl != null && _isHlsStream(_currentStreamUrl!);

    if (isHls) {
      if (rawBufferAhead > _lastRawHlsBuffer) {
        _hlsBufferedDuration += rawBufferAhead - _lastRawHlsBuffer;
      }
      _lastRawHlsBuffer = rawBufferAhead;

      final playlistWindow =
          _currentHlsPlaylistWindow ?? AudioConfig.hlsTargetForwardBuffer;
      if (_hlsBufferedDuration > playlistWindow) {
        _hlsBufferedDuration = playlistWindow;
      }
      _currentBufferSize = _hlsBufferedDuration;

      // HLS ghost playback detection - softer approach
      if (_audioPlayer.playing && _currentState.isPlaying) {
        // For HLS we only check for critical stalls (60+ seconds without changes)
        if (rawBufferAhead == _lastBufferSize) {
          _stuckBufferCount++;

          // Only after 2 minutes of no movement do we treat it as a real problem
          if (_stuckBufferCount >= 120) {
            // 120 updates ≈ 60 seconds
            Logger.error(
                '🚨 HLS CRITICAL: Buffer completely stuck for 60s at ${rawBufferAhead.inSeconds}s');
            _handlePlayerError(Exception('HLS buffer critically stuck'));
            _stuckBufferCount = 0;
            return;
          }
        } else {
          _stuckBufferCount = 0;
        }
        _lastBufferSize = rawBufferAhead;
      }
    } else {
      // Regular stream: Adaptive buffering for typical streams
      final timePlaying = _streamStartTime != null
          ? DateTime.now().difference(_streamStartTime!)
          : Duration.zero;

      // Use a moderate cap for regular streams
      if (rawBufferAhead.inSeconds <= 2) {
        if (timePlaying.inSeconds < 5) {
          _currentBufferSize = Duration(seconds: 3);
        } else {
          _currentBufferSize = Duration(seconds: 5);
        }
      } else {
        // Allow up to 20 seconds for regular streams (compromise)
        _currentBufferSize =
            Duration(seconds: rawBufferAhead.inSeconds.clamp(0, 20));
      }

      // Stricter ghost detection for regular streams
      if (_audioPlayer.playing && _currentState.isPlaying) {
        if (rawBufferAhead == _lastBufferSize) {
          _stuckBufferCount++;

          if (_stuckBufferCount >= 30) {
            // 15 seconds for regular streams
            Logger.error(
                '🚨 STREAM GHOST: Buffer stuck at ${rawBufferAhead.inSeconds}s');
            _handlePlayerError(Exception('Stream buffer stuck'));
            _stuckBufferCount = 0;
            return;
          }
        } else {
          _stuckBufferCount = 0;
        }
        _lastBufferSize = rawBufferAhead;
      }
    }

    _lastBufferUpdate = DateTime.now();

    _updateBufferSizeState();
  }

  void _updateBufferSizeState() {
    if (_currentState case AudioStatePlaying playing) {
      final newState = playing.copyWith(bufferSize: _currentBufferSize);
      _currentState = newState;
      _stateController.add(_currentState);
    } else if (_currentState case AudioStateBuffering buffering) {
      _currentState = buffering.copyWith(bufferSize: _currentBufferSize);
      _stateController.add(_currentState);
    } else if (_currentState case AudioStatePaused paused) {
      _currentState = paused.copyWith(bufferSize: _currentBufferSize);
      _stateController.add(_currentState);
    }
  }

  void _resetHlsTracking() {
    _hlsBufferedDuration = Duration.zero;
    _currentHlsPlaylistWindow = null;
    _currentBufferSize = Duration.zero;
    _lastRawHlsBuffer = Duration.zero;
    _lastPlaybackPosition = Duration.zero;
  }

  void _resetStallTracking() {
    _lastProgressPosition = Duration.zero;
    _lastProgressAt = null;
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final hasConnection = results.any((result) =>
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.ethernet);

    final connectionType = switch (results.firstOrNull) {
      ConnectivityResult.wifi => ConnectionType.wifi,
      ConnectivityResult.mobile => ConnectionType.mobile,
      ConnectivityResult.ethernet => ConnectionType.ethernet,
      _ => ConnectionType.unknown,
    };

    final isActuallyConnected = hasConnection;

    final previouslyConnected = _networkState.isConnected;
    if (isActuallyConnected != previouslyConnected) {
      _networkState = _networkState.copyWith(
        isConnected: isActuallyConnected,
        type: connectionType,
        lastDisconnection: isActuallyConnected ? null : DateTime.now(),
      );

      _networkController.add(_networkState);

      Logger.info(
          'Network state CHANGED: ${isActuallyConnected ? 'Connected' : 'Disconnected'} (${connectionType.displayName})${_currentState.isPlaying ? ' [inferred from playing audio]' : ''}');
    } else {
      _networkState = _networkState.copyWith(type: connectionType);
      Logger.debug(
          'Network type updated: ${connectionType.displayName} (still ${isActuallyConnected ? 'connected' : 'disconnected'})');
    }
  }

  void _handlePlayerError(dynamic error) {
    final errorMessage = error.toString();
    Logger.error('🎵 ERROR_DEBUG: ===== PLAYER ERROR OCCURRED =====');
    Logger.error('🎵 ERROR_DEBUG: Error type: ${error.runtimeType}');
    Logger.error('🎵 ERROR_DEBUG: Error message: $errorMessage');
    Logger.error('🎵 ERROR_DEBUG: Current config: $_currentConfig');

    if (errorMessage.contains('400')) {
      Logger.error(
          '🎵 ERROR_DEBUG: HTTP 400 Bad Request - possible stream unavailable or wrong headers');
    } else if (errorMessage.contains('403')) {
      Logger.error(
          '🎵 ERROR_DEBUG: HTTP 403 Forbidden - stream may require authorization');
    } else if (errorMessage.contains('404')) {
      Logger.error(
          '🎵 ERROR_DEBUG: HTTP 404 Not Found - stream URL may be incorrect');
    } else if (errorMessage.contains('loading interrupted')) {
      Logger.error(
          '🎵 ERROR_DEBUG: Stream loading was interrupted - possible network or header issue');
    } else {
      Logger.error('🎵 ERROR_DEBUG: Unrecognized error type');
    }

    final simplifiedMessage = _simplifyErrorMessage(errorMessage);
    final isRetryable = _isRetryableError(errorMessage);

    Logger.error('🎵 ERROR_DEBUG: Simplified message: $simplifiedMessage');
    Logger.error('🎵 ERROR_DEBUG: Is retryable: $isRetryable');

    _currentState = AudioStateError(
      message: simplifiedMessage,
      exception: error is Exception ? error : Exception(errorMessage),
      config: _currentConfig,
      isRetryable: isRetryable,
    );

    _stateController.add(_currentState);
    Logger.error('🎵 ERROR_DEBUG: Error state emitted');
  }

  String _simplifyErrorMessage(String error) {
    final lowerError = error.toLowerCase();
    if (lowerError.contains('network') || lowerError.contains('connection')) {
      return 'Network error';
    } else if (lowerError.contains('format') || lowerError.contains('codec')) {
      return 'Format error';
    } else if (lowerError.contains('timeout')) {
      return 'Connection timeout';
    } else if (lowerError.contains('400') ||
        lowerError.contains('bad request')) {
      return 'Stream unavailable (400)';
    } else if (lowerError.contains('404') || lowerError.contains('not found')) {
      return 'Stream not found (404)';
    } else if (lowerError.contains('403') || lowerError.contains('forbidden')) {
      return 'Access denied (403)';
    } else if (lowerError.contains('loading interrupted')) {
      return 'Stream loading interrupted';
    }
    return 'Playback error: $error';
  }

  bool _isRetryableError(String error) {
    final lowerError = error.toLowerCase();
    return lowerError.contains('network') ||
        lowerError.contains('connection') ||
        lowerError.contains('timeout');
  }

  void _startLoadingTimeout() {
    _cancelTimeouts();
    _loadingTimeoutTimer = Timer(_loadingTimeout, () {
      if (_currentState is AudioStateLoading) {
        Logger.error(
            'Loading timeout after ${_loadingTimeout.inSeconds}s - forcing retry');
        _currentState = AudioStateError(
          message: 'Loading timeout',
          config: _currentConfig,
          isRetryable: true,
        );
        _stateController.add(_currentState);
      }
    });
  }

  void _startHangDetection() {
    _hangDetectionTimer =
        Timer.periodic(_hangDetectionInterval, _checkForHangs);
  }

  void _checkForHangs(Timer timer) {
    if (_isDisposed) {
      timer.cancel();
      return;
    }

    final now = DateTime.now();
    final isHls = _currentStreamUrl != null && _isHlsStream(_currentStreamUrl!);

    // PLAYBACK STALL: the player still reports playing=true but the playback
    // position has stopped advancing. This is the signature of a "silent"
    // network stall on live/HLS streams (e.g. flaky Wi-Fi on Samsung TVs) where
    // the source keeps the player buffering without surfacing an error and
    // connectivity_plus stays "online". We synthesise a network error so the
    // normal restart -> failover recovery path can run. Local failover playback
    // is skipped here (_currentStreamUrl is null while playing a cached file).
    if (_audioPlayer.playing &&
        !_isPlayStreamInProgress &&
        _currentStreamUrl != null &&
        _streamStartTime != null) {
      final position = _audioPlayer.position;
      if (position > _lastProgressPosition) {
        _lastProgressPosition = position;
        _lastProgressAt = now;
      } else if (_lastProgressPosition > Duration.zero) {
        final frozenFor = now.difference(_lastProgressAt ?? now);
        final stallTimeout =
            isHls ? _playbackStallTimeoutHls : _playbackStallTimeout;
        if (frozenFor >= stallTimeout) {
          Logger.error(
              '🚨 PLAYBACK STALL: position frozen at ${position.inSeconds}s for ${frozenFor.inSeconds}s while playing (${isHls ? 'HLS' : 'live'}) - raising network error');
          // Reset so we don't re-fire on every tick while recovery is running.
          _lastProgressAt = now;
          _handlePlayerError(Exception(
              'Network error: playback stalled for ${frozenFor.inSeconds}s without progress'));
          return;
        }
      }
    }

    if (_currentState.isPlaying &&
        _audioPlayer.playing &&
        _currentStreamUrl != null &&
        _lastBufferUpdate != null &&
        _streamStartTime != null) {
      final timeSinceStart = now.difference(_streamStartTime!);
      final bufferStalledFor = now.difference(_lastBufferUpdate!);

      // Use softer timeouts for HLS
      final stallThreshold = isHls
          ? const Duration(seconds: 60) // HLS: 60 seconds
          : _bufferStallThreshold; // Regular: 20 seconds

      if (timeSinceStart > stallThreshold &&
          bufferStalledFor > stallThreshold) {
        Logger.error(
            '${isHls ? "HLS" : "STREAM"} STALL: No buffer updates for ${bufferStalledFor.inSeconds}s');
        _handlePlayerError(
            TimeoutException('Buffer stalled during playback', stallThreshold));
        return;
      }
    }

    // The rest of the hang detection logic stays the same...
    if (_currentState case AudioStateLoading loading) {
      if (loading.elapsed > _maxHangTime && !_audioPlayer.playing) {
        Logger.error('Detected loading hang: ${loading.elapsed.inSeconds}s');
        _handlePlayerError(
            TimeoutException('Loading hang detected', _maxHangTime));
      }
    } else if (_currentState case AudioStateBuffering buffering) {
      if (buffering.elapsed > _maxHangTime && !_audioPlayer.playing) {
        Logger.error(
            'Detected buffering hang: ${buffering.elapsed.inSeconds}s');
        _handlePlayerError(
            TimeoutException('Buffering hang detected', _maxHangTime));
      }
    }
  }

  void _cancelTimeouts() {
    _loadingTimeoutTimer?.cancel();
    _loadingTimeoutTimer = null;
  }

  Future<void> _handlePlayerOperationTimeout({
    required String operation,
    required Duration timeout,
    required Duration elapsed,
  }) async {
    Logger.error(
        '🎵 AUDIO_DEBUG: $operation timed out after ${elapsed.inSeconds}s (limit ${timeout.inSeconds}s) - forcing player stop');
    await _forceStopPlayer('timeout during $operation');
  }

  Future<void> _forceStopPlayer(String reason) async {
    Logger.warning('🎵 AUDIO_DEBUG: Force stopping player due to $reason');
    await _stopPlayerSafely('force stop: $reason');
    _isPlayingStream = false;
    _currentStreamUrl = null;
    await _disposeActiveHlsSource();
    _resetHlsTracking();
  }

  void _updatePlaybackStats() {
    _playbackStats = _playbackStats.copyWith(
      reconnectCount: _playbackStats.reconnectCount + 1,
      lastReconnect: DateTime.now(),
    );
  }

  @override
  Future<Result<void>> playStream(StreamConfig config,
      {bool quickStart = false}) async {
    if (!_isInitialized) {
      final initResult = await initialize();
      if (initResult.isFailure) return initResult;
    }

    return tryResultAsync(() async {
      Logger.info('🎵 AUDIO_DEBUG: ===== STARTING PLAYBACK =====');
      Logger.info('🎵 AUDIO_DEBUG: Title: ${config.title}');
      Logger.info('🎵 AUDIO_DEBUG: Stream URL: ${config.streamUrl}');
      Logger.info(
          '🎵 AUDIO_DEBUG: Volume (master): ${config.volume}, failover: ${config.failoverVolume}');
      Logger.info(
          '🎵 AUDIO_DEBUG: Current _isPlayingStream: $_isPlayingStream');
      Logger.info('🎵 AUDIO_DEBUG: Current stream URL: $_currentStreamUrl');

      // Prevent concurrent playStream calls
      if (_isPlayStreamInProgress) {
        Logger.warning(
            '🎵 AUDIO_DEBUG: ⚠️ playStream already in progress, ignoring duplicate call');
        return;
      }

      if (_isPlayingStream && _currentStreamUrl == config.streamUrl) {
        Logger.warning(
            '🎵 AUDIO_DEBUG: ⚠️ Already playing the same stream, ignoring duplicate call');
        return;
      }

      if (_isPlayingStream && _currentStreamUrl != config.streamUrl) {
        Logger.info('🎵 AUDIO_DEBUG: Stopping current stream to play new one');
        await _stopPlayerSafely('stream switch to ${config.streamUrl}');
        _isPlayingStream = false;
      }

      _isPlayStreamInProgress = true;
      _isPlayingStream = true;
      _currentStreamUrl = config.streamUrl;
      Logger.info('🎵 AUDIO_DEBUG: Set _isPlayingStream = true');

      try {
        _streamStartTime = DateTime.now();
        _currentConfig = config;
        Logger.info('🎵 AUDIO_DEBUG: Stream start time and config set');
        _userPaused = false;
        _awaitingInterruptionResume = false;
        _lastPlaybackPosition = Duration.zero;

        final isHls = _isHlsStream(config.streamUrl);
        _resetHlsTracking();
        _resetStallTracking();
        if (_isCurrentLoadConfigurationHls != isHls) {
          Logger.info(
              '🎵 AUDIO_DEBUG: Rebuilding audio player for ${isHls ? 'HLS' : 'live'} buffering profile');
          await _resetAudioPlayer('load profile switch', isHlsOverride: isHls);
        }
        _isCurrentLoadConfigurationHls = isHls;

        final prebufferDelay = quickStart
            ? Duration.zero
            : await _calculateOptimalPrebufferDelay(isHls: isHls);
        if (prebufferDelay > Duration.zero) {
          Logger.info(
              '🎵 AUDIO_DEBUG: Pre-buffering for ${prebufferDelay.inMilliseconds}ms for stable connection...');
          await Future.delayed(prebufferDelay);
        }

        Logger.info('🎵 AUDIO_DEBUG: Setting audio source...');

        await _disposeActiveHlsSource();

        final streamTag = {
          'title': config.title ?? 'Live Stream',
          'artist': config.description ?? '',
        };
        final streamHeaders = AudioConfig.getStreamingHeaders();

        final AudioSource audioSource;
        if (isHls) {
          if (Platform.isWindows) {
            // just_audio_windows notes byte stream support is not tested,
            // so prefer native HLS via URL on Windows.
            Logger.info('🎵 AUDIO_DEBUG: Using native HLS playback on Windows');
            audioSource = AudioSource.uri(
              Uri.parse(config.streamUrl),
              headers: streamHeaders,
              tag: streamTag,
            );
          } else {
            audioSource = _activeHlsSource = HlsStreamAudioSource(
              playlistUri: Uri.parse(config.streamUrl),
              headers: streamHeaders,
              onPlaylistInfo: (info) {
                final total = info.totalDuration;
                _currentHlsPlaylistWindow = total;
              },
              tag: streamTag,
            );
          }
        } else {
          audioSource = AudioSource.uri(
            Uri.parse(config.streamUrl),
            headers: streamHeaders,
            tag: streamTag,
          );
        }

        Logger.info('🎵 AUDIO_DEBUG: About to call setAudioSource...');
        final setSourceTimeout = quickStart
            ? const Duration(seconds: 5)
            : (isHls && Platform.isMacOS
                ? const Duration(seconds: 30)
                : const Duration(seconds: 15));
        final setSourceStartTime = DateTime.now();
        try {
          await _audioPlayer
              .setAudioSource(
                audioSource,
                initialPosition: Duration.zero,
                preload: true,
              )
              .timeout(setSourceTimeout);

          final setSourceDuration =
              DateTime.now().difference(setSourceStartTime);
          Logger.info(
              '🎵 AUDIO_DEBUG: setAudioSource completed successfully in ${setSourceDuration.inMilliseconds}ms');
        } on TimeoutException catch (_) {
          final elapsed = DateTime.now().difference(setSourceStartTime);
          await _handlePlayerOperationTimeout(
            operation: 'setAudioSource',
            timeout: setSourceTimeout,
            elapsed: elapsed,
          );
          throw TimeoutException('setAudioSource operation timed out');
        } catch (e, stackTrace) {
          Logger.error('🎵 AUDIO_DEBUG: setAudioSource FAILED: $e');
          Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
          rethrow;
        }

        final liveStreamVolume = config.volume.clamp(0.0, 1.0);
        Logger.info(
            '🎵 AUDIO_DEBUG: Applying live stream volume override: $liveStreamVolume');
        try {
          await setVolume(liveStreamVolume);
          Logger.info('🎵 AUDIO_DEBUG: Live stream volume set successfully');
        } catch (e, stackTrace) {
          Logger.error('🎵 AUDIO_DEBUG: setVolume FAILED: $e');
          Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
          rethrow;
        }

        Logger.info('🎵 AUDIO_DEBUG: About to call play()...');
        final playTimeout = quickStart
            ? const Duration(seconds: 5)
            : const Duration(seconds: 30);
        final playStartTime = DateTime.now();
        try {
          await _audioPlayer.play().timeout(playTimeout);

          final playDuration = DateTime.now().difference(playStartTime);
          Logger.info(
              '🎵 AUDIO_DEBUG: play() completed in ${playDuration.inMilliseconds}ms');
          Logger.info(
              '🎵 AUDIO_DEBUG: Player state after play(): ${_audioPlayer.playing}');
        } on TimeoutException catch (_) {
          final elapsed = DateTime.now().difference(playStartTime);

          if (_audioPlayer.playing) {
            Logger.warning(
                '🎵 AUDIO_DEBUG: play() call timed out after ${elapsed.inSeconds}s BUT player is actually playing - ignoring timeout');
          } else {
            Logger.error(
                '🎵 AUDIO_DEBUG: play() timed out after ${elapsed.inSeconds}s and player NOT playing');
            await _handlePlayerOperationTimeout(
              operation: 'play()',
              timeout: playTimeout,
              elapsed: elapsed,
            );
            throw TimeoutException('play operation timed out');
          }
        } catch (e, stackTrace) {
          if (_audioPlayer.playing) {
            Logger.warning(
                '🎵 AUDIO_DEBUG: play() threw error BUT player is actually playing - ignoring error');
            Logger.warning('🎵 AUDIO_DEBUG: Error was: $e');
          } else {
            Logger.error('🎵 AUDIO_DEBUG: play() FAILED: $e');
            Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
            rethrow;
          }
        }

        Logger.info(
            '🎵 AUDIO_DEBUG: ===== PLAYBACK STARTED SUCCESSFULLY =====');
      } catch (e) {
        // On error, clean up state
        Logger.error('🎵 AUDIO_DEBUG: Playback failed, cleaning up: $e');
        _isPlayingStream = false;
        _currentStreamUrl = null;
        _resetHlsTracking();
        rethrow;
      } finally {
        _isPlayStreamInProgress = false;
        Logger.info('🎵 AUDIO_DEBUG: playStream operation completed');
      }
    });
  }

  @override
  Future<Result<void>> playLocalFile(String filePath,
      {StreamConfig? originalConfig}) async {
    if (!_isInitialized) {
      final initResult = await initialize();
      if (initResult.isFailure) return initResult;
    }

    return tryResultAsync(() async {
      Logger.info('🎵 FAILOVER: ===== STARTING LOCAL FILE PLAYBACK =====');
      Logger.info('🎵 FAILOVER: File path: $filePath');
      Logger.info('🎵 FAILOVER: Original config: ${originalConfig?.title}');

      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Local file not found: $filePath');
      }

      // Prevent concurrent playLocalFile calls
      if (_isPlayStreamInProgress) {
        Logger.warning(
            '🎵 FAILOVER: ⚠️ Another playback operation in progress, waiting...');
        // Give some time for the other operation to complete
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (_isPlayingStream) {
        Logger.info('🎵 FAILOVER: Stopping current stream for failover');
        await _stopPlayerSafely('failover switch to $filePath');
        _isPlayingStream = false;
      }

      _isPlayStreamInProgress = true;
      _isPlayingStream = true;
      _currentStreamUrl = null;

      try {
        _streamStartTime = DateTime.now();

        _currentConfig = originalConfig ??
            StreamConfig(
              streamUrl: filePath,
              title: 'Failover Track',
              description: 'Playing from local cache',
              volume: _currentVolume,
            );
        _userPaused = false;
        _awaitingInterruptionResume = false;
        _lastPlaybackPosition = Duration.zero;
        _resetHlsTracking();
        _resetStallTracking();

        Logger.info('🎵 FAILOVER: Creating audio source from local file...');
        final audioSource = AudioSource.file(
          filePath,
          tag: {
            'title': _currentConfig!.title ?? 'Failover Track',
            'artist': _currentConfig!.description ?? '',
          },
        );

        Logger.info('🎵 FAILOVER: Setting audio source...');
        const failoverSetSourceTimeout = Duration(seconds: 10);
        final failoverSetSourceStart = DateTime.now();
        try {
          await _audioPlayer
              .setAudioSource(
                audioSource,
                initialPosition: Duration.zero,
                preload: true,
              )
              .timeout(failoverSetSourceTimeout);
        } on TimeoutException catch (_) {
          final elapsed = DateTime.now().difference(failoverSetSourceStart);
          Logger.error('🎵 FAILOVER: setAudioSource timed out');
          await _handlePlayerOperationTimeout(
            operation: 'failover setAudioSource',
            timeout: failoverSetSourceTimeout,
            elapsed: elapsed,
          );
          throw TimeoutException('setAudioSource operation timed out');
        }

        Logger.info('🎵 FAILOVER: Setting volume...');
        await _audioPlayer.setVolume(_currentVolume);

        Logger.info('🎵 FAILOVER: Starting playback...');
        const failoverPlayTimeout = Duration(seconds: 5);
        final failoverPlayStart = DateTime.now();
        try {
          await _audioPlayer.play().timeout(failoverPlayTimeout);
        } on TimeoutException catch (_) {
          final elapsed = DateTime.now().difference(failoverPlayStart);

          if (_audioPlayer.playing) {
            Logger.warning(
                '🎵 FAILOVER: play() call timed out after ${elapsed.inSeconds}s BUT player is actually playing - ignoring timeout');
          } else {
            Logger.error(
                '🎵 FAILOVER: play() timed out after ${elapsed.inSeconds}s and player NOT playing');
            await _handlePlayerOperationTimeout(
              operation: 'failover play()',
              timeout: failoverPlayTimeout,
              elapsed: elapsed,
            );
            throw TimeoutException('play operation timed out');
          }
        } catch (e, stackTrace) {
          if (_audioPlayer.playing) {
            Logger.warning(
                '🎵 FAILOVER: play() threw error BUT player is actually playing - ignoring error');
            Logger.warning('🎵 FAILOVER: Error was: $e');
          } else {
            Logger.error('🎵 FAILOVER: play() FAILED: $e');
            Logger.error('🎵 FAILOVER: Stack trace: $stackTrace');
            rethrow;
          }
        }

        Logger.info(
            '🎵 FAILOVER: ===== LOCAL FILE PLAYBACK STARTED SUCCESSFULLY =====');
      } catch (e) {
        // On error, clean up state
        Logger.error('🎵 FAILOVER: Playback failed, cleaning up: $e');
        _isPlayingStream = false;
        _currentStreamUrl = null;
        _resetHlsTracking();
        rethrow;
      } finally {
        _isPlayStreamInProgress = false;
      }
    });
  }

  @override
  Future<Result<void>> pause() async {
    return tryResultAsync(() async {
      _userPaused = true;
      _awaitingInterruptionResume = false;
      await _audioPlayer.pause();
      Logger.info('Playback paused');
    });
  }

  @override
  Future<Result<void>> resume() async {
    return tryResultAsync(() async {
      _userPaused = false;
      await _audioPlayer.play();
      Logger.info('Playback resumed');
    });
  }

  @override
  Future<Result<void>> stop() async {
    return tryResultAsync(() async {
      Logger.info('🎵 AUDIO_DEBUG: Stopping playback...');
      _cancelTimeouts();

      // Wait for any in-progress playback operation to complete
      if (_isPlayStreamInProgress) {
        Logger.warning(
            '🎵 AUDIO_DEBUG: Waiting for in-progress playback operation...');
        await Future.delayed(const Duration(milliseconds: 200));
      }

      await _stopPlayerSafely('service stop()');

      _currentConfig = null;
      _streamStartTime = null;
      _userPaused = false;
      _awaitingInterruptionResume = false;

      // Reset ghost playback detection
      _stuckBufferCount = 0;
      _lastBufferSize = Duration.zero;
      _resetStallTracking();
      _isPlayingStream = false;
      _isPlayStreamInProgress = false;
      _currentStreamUrl = null;
      await _disposeActiveHlsSource();
      _lastPlaybackPosition = Duration.zero;

      _currentState = const AudioStateIdle();
      _stateController.add(_currentState);

      Logger.info('Playback stopped');
    });
  }

  @override
  Future<Result<void>> setVolume(double volume) async {
    return tryResultAsync(() async {
      _currentVolume = volume.clamp(0.0, 1.0);
      await _audioPlayer.setVolume(_currentVolume);
    });
  }

  Future<Duration> _calculateOptimalPrebufferDelay(
      {required bool isHls}) async {
    if (isHls) {
      // For HLS we rely on playlist buffering rather than delaying start.
      Logger.info(
          '🎯 HLS BUFFER: Skipping artificial prebuffer delay for HLS stream');
      return Duration.zero;
    }
    try {
      final stopwatch = Stopwatch()..start();

      try {
        final result = await InternetAddress.lookup('google.com')
            .timeout(const Duration(seconds: 2));
        stopwatch.stop();

        if (result.isNotEmpty) {
          final responseTime = stopwatch.elapsedMilliseconds;
          Logger.info('🌐 NETWORK: Connectivity test: ${responseTime}ms');

          if (responseTime < 100) {
            Logger.info(
                '🌐 NETWORK: Fast network detected - AAC pre-buffer 2s');
            return const Duration(seconds: 2);
          } else if (responseTime < 500) {
            Logger.info(
                '🌐 NETWORK: Medium network detected - AAC pre-buffer 3s');
            return const Duration(seconds: 3);
          } else {
            Logger.info(
                '🌐 NETWORK: Slow network detected - AAC pre-buffer 4s');
            return const Duration(seconds: 4);
          }
        }
      } catch (e) {
        Logger.warning('🌐 NETWORK: Connectivity test failed: $e');
      }
    } catch (e) {
      Logger.warning('🌐 NETWORK: Pre-buffer calculation failed: $e');
    }

    Logger.info('🌐 NETWORK: Using default AAC pre-buffer delay');
    return const Duration(seconds: 3);
  }

  Future<void> _disposeActiveHlsSource() async {
    if (_activeHlsSource == null) {
      return;
    }
    try {
      await _activeHlsSource!.close();
    } catch (e, stackTrace) {
      Logger.warning('Failed to dispose active HLS source: $e');
      Logger.debug('$stackTrace');
    } finally {
      _activeHlsSource = null;
      _resetHlsTracking();
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    Logger.info('Disposing AudioService');

    _cancelTimeouts();
    _hangDetectionTimer?.cancel();

    await _playerStateSubscription?.cancel();
    await _playbackEventSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _bufferSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    await _interruptionSubscription?.cancel();

    await _audioPlayer.dispose();
    await _disposeActiveHlsSource();
    await _stateController.close();
    await _networkController.close();

    Logger.info('AudioService disposed');
  }
}

extension AudioStatePlayingCopyWith on AudioStatePlaying {
  AudioStatePlaying copyWith({
    StreamConfig? config,
    Duration? position,
    Duration? bufferSize,
    PlaybackStats? stats,
  }) =>
      AudioStatePlaying(
        config: config ?? this.config,
        position: position ?? this.position,
        bufferSize: bufferSize ?? this.bufferSize,
        stats: stats ?? this.stats,
      );
}

extension AudioStateBufferingCopyWith on AudioStateBuffering {
  AudioStateBuffering copyWith({
    StreamConfig? config,
    Duration? bufferSize,
    Duration? elapsed,
  }) =>
      AudioStateBuffering(
        config: config ?? this.config,
        bufferSize: bufferSize ?? this.bufferSize,
        elapsed: elapsed ?? this.elapsed,
      );
}

extension AudioStatePausedCopyWith on AudioStatePaused {
  AudioStatePaused copyWith({
    StreamConfig? config,
    Duration? position,
    Duration? bufferSize,
  }) =>
      AudioStatePaused(
        config: config ?? this.config,
        position: position ?? this.position,
        bufferSize: bufferSize ?? this.bufferSize,
      );
}
