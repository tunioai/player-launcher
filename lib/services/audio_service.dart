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

abstract interface class IAudioService implements Disposable {
  Stream<AudioState> get stateStream;
  Stream<NetworkState> get networkStream;
  AudioState get currentState;

  Future<Result<void>> initialize();
  Future<Result<void>> playStream(StreamConfig config);
  Future<Result<void>> playLocalFile(String filePath,
      {StreamConfig? originalConfig});
  Future<Result<void>> pause();
  Future<Result<void>> resume();
  Future<Result<void>> stop();
  Future<Result<void>> setVolume(double volume);

  double get volume;
}

final class EnhancedAudioService implements IAudioService {
  late final AudioPlayer _audioPlayer;

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<NetworkState> _networkController =
      StreamController<NetworkState>.broadcast();

  AudioState _currentState = const AudioStateIdle();
  NetworkState _networkState =
      const NetworkState(isConnected: false, type: ConnectionType.unknown);

  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _bufferSubscription;
  StreamSubscription<int?>? _currentIndexSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  StreamConfig? _currentConfig;

  double _currentVolume = 1.0;

  PlaybackStats _playbackStats = const PlaybackStats();
  DateTime? _streamStartTime;
  DateTime? _lastBufferUpdate;
  Duration _currentBufferSize = Duration.zero;

  Timer? _loadingTimeoutTimer;
  Timer? _hangDetectionTimer;

  final Completer<void> _initializationCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _isPlayingStream = false;
  String? _currentStreamUrl;

  static const Duration _loadingTimeout = Duration(seconds: 60);
  static const Duration _hangDetectionInterval = Duration(seconds: 30);
  static const Duration _maxHangTime = Duration(seconds: 90);

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
    if (_initializationCompleter.isCompleted) {
      await _initializationCompleter.future;
      return const Success(null);
    }

    return tryResultAsync(() async {
      await _initializeAudioPlayer();
      _setupSubscriptions();
      _startHangDetection();

      _isInitialized = true;
      _initializationCompleter.complete();

      Logger.info('AudioService: Initialized successfully');
    });
  }

  Future<void> _initializeAudioPlayer() async {
    Logger.info('🎵 INIT_DEBUG: ===== INITIALIZING AUDIO PLAYER =====');
    Logger.info('🎵 INIT_DEBUG: User agent: ${AudioConfig.userAgent}');

    _audioPlayer = AudioPlayer(
      userAgent: AudioConfig.userAgent,
    );

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.duckOthers,
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

    Logger.info('🎵 INIT_DEBUG: AudioPlayer instance created');
    Logger.info('🎵 INIT_DEBUG: Audio session configured');
    Logger.info('🎵 INIT_DEBUG: ===== AUDIO PLAYER INITIALIZED =====');
  }

  void _setupSubscriptions() {
    _playerStateSubscription = _audioPlayer.playerStateStream.listen(
      _handlePlayerStateChange,
      onError: _handlePlayerError,
    );

    _positionSubscription = _audioPlayer.positionStream.listen(
      _handlePositionUpdate,
      onError: (error) => Logger.error('Position stream error: $error'),
    );

    _bufferSubscription = _audioPlayer.bufferedPositionStream.listen(
      _handleBufferUpdate,
      onError: (error) => Logger.error('Buffer stream error: $error'),
    );

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

    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
          _handleConnectivityChange,
          onError: (error) => Logger.error('Connectivity stream error: $error'),
        );

    _checkInitialNetworkState();
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
      final playing = _currentState as AudioStatePlaying;
      _currentState = playing.copyWith(position: position);
      _stateController.add(_currentState);
    }
  }

  void _handleBufferUpdate(Duration? bufferedPosition) {
    if (bufferedPosition == null) return;

    final currentPosition = _audioPlayer.position;
    final rawBufferAhead = bufferedPosition - currentPosition;

    final timePlaying = _streamStartTime != null
        ? DateTime.now().difference(_streamStartTime!)
        : Duration.zero;

    if (rawBufferAhead.inSeconds <= 2) {
      if (timePlaying.inSeconds < 5) {
        _currentBufferSize = Duration(seconds: 3);
      } else {
        _currentBufferSize = Duration(seconds: 5);
      }
    } else {
      _currentBufferSize =
          Duration(seconds: rawBufferAhead.inSeconds.clamp(0, 8));
    }

    _lastBufferUpdate = DateTime.now();

    if (_currentState case AudioStatePlaying playing) {
      final newState = playing.copyWith(bufferSize: _currentBufferSize);

      _currentState = newState;
      _stateController.add(_currentState);
    } else if (_currentState case AudioStateBuffering buffering) {
      _currentState = buffering.copyWith(bufferSize: _currentBufferSize);
      _stateController.add(_currentState);
    }
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

    final isActuallyConnected = hasConnection || _currentState.isPlaying;

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

    if (_lastBufferUpdate != null &&
        _currentState.isPlaying &&
        !_audioPlayer.playing &&
        now.difference(_lastBufferUpdate!) > Duration(minutes: 2) &&
        _audioPlayer.position.inSeconds == 0) {
      Logger.error('Buffer update hang detected (position also stuck)');
      _handlePlayerError(
          TimeoutException('Buffer update hang', Duration(minutes: 2)));
    }
  }

  void _cancelTimeouts() {
    _loadingTimeoutTimer?.cancel();
    _loadingTimeoutTimer = null;
  }

  void _updatePlaybackStats() {
    _playbackStats = _playbackStats.copyWith(
      reconnectCount: _playbackStats.reconnectCount + 1,
      lastReconnect: DateTime.now(),
    );
  }

  @override
  Future<Result<void>> playStream(StreamConfig config) async {
    if (!_isInitialized) {
      final initResult = await initialize();
      if (initResult.isFailure) return initResult;
    }

    return tryResultAsync(() async {
      Logger.info('🎵 AUDIO_DEBUG: ===== STARTING PLAYBACK =====');
      Logger.info('🎵 AUDIO_DEBUG: Title: ${config.title}');
      Logger.info('🎵 AUDIO_DEBUG: Stream URL: ${config.streamUrl}');
      Logger.info('🎵 AUDIO_DEBUG: Volume: ${config.volume}');
      Logger.info(
          '🎵 AUDIO_DEBUG: Current _isPlayingStream: $_isPlayingStream');
      Logger.info('🎵 AUDIO_DEBUG: Current stream URL: $_currentStreamUrl');

      if (_isPlayingStream && _currentStreamUrl == config.streamUrl) {
        Logger.warning(
            '🎵 AUDIO_DEBUG: ⚠️ Already playing the same stream, ignoring duplicate call');
        return;
      }

      if (_isPlayingStream && _currentStreamUrl != config.streamUrl) {
        Logger.info('🎵 AUDIO_DEBUG: Stopping current stream to play new one');
        await _audioPlayer.stop();
        _isPlayingStream = false;
      }

      _isPlayingStream = true;
      _currentStreamUrl = config.streamUrl;
      Logger.info('🎵 AUDIO_DEBUG: Set _isPlayingStream = true');

      try {
        _streamStartTime = DateTime.now();
        _currentConfig = config;
        Logger.info('🎵 AUDIO_DEBUG: Stream start time and config set');

        final prebufferDelay = await _calculateOptimalPrebufferDelay();
        Logger.info(
            '🎵 AUDIO_DEBUG: Pre-buffering for ${prebufferDelay.inSeconds}s for stable connection...');
        await Future.delayed(prebufferDelay);

        Logger.info('🎵 AUDIO_DEBUG: Setting audio source...');

        final audioSource = AudioSource.uri(
          Uri.parse(config.streamUrl),
          headers: AudioConfig.getStreamingHeaders(),
          tag: {
            'title': config.title ?? 'Live Stream',
            'artist': config.description ?? '',
          },
        );

        Logger.info('🎵 AUDIO_DEBUG: About to call setAudioSource...');
        try {
          final setSourceStartTime = DateTime.now();
          await _audioPlayer
              .setAudioSource(
            audioSource,
            initialPosition: Duration.zero,
            preload: true,
          )
              .timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              final elapsed = DateTime.now().difference(setSourceStartTime);
              Logger.error(
                  '🎵 AUDIO_DEBUG: setAudioSource timed out after ${elapsed.inSeconds}s');
              throw TimeoutException('setAudioSource operation timed out');
            },
          );
          final setSourceDuration =
              DateTime.now().difference(setSourceStartTime);
          Logger.info(
              '🎵 AUDIO_DEBUG: setAudioSource completed successfully in ${setSourceDuration.inMilliseconds}ms');
        } catch (e, stackTrace) {
          Logger.error('🎵 AUDIO_DEBUG: setAudioSource FAILED: $e');
          Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
          rethrow;
        }

        Logger.info(
            '🎵 AUDIO_DEBUG: About to set volume to ${config.volume}...');
        try {
          await setVolume(config.volume);
          Logger.info('🎵 AUDIO_DEBUG: Volume set successfully');
        } catch (e, stackTrace) {
          Logger.error('🎵 AUDIO_DEBUG: setVolume FAILED: $e');
          Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
          rethrow;
        }

        Logger.info('🎵 AUDIO_DEBUG: About to call play()...');
        try {
          final playStartTime = DateTime.now();
          await _audioPlayer.play().timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              final elapsed = DateTime.now().difference(playStartTime);
              Logger.error(
                  '🎵 AUDIO_DEBUG: play() timed out after ${elapsed.inSeconds}s');
              throw TimeoutException('play operation timed out');
            },
          );
          final playDuration = DateTime.now().difference(playStartTime);
          Logger.info(
              '🎵 AUDIO_DEBUG: play() completed successfully in ${playDuration.inMilliseconds}ms');
          Logger.info(
              '🎵 AUDIO_DEBUG: Player state after play(): ${_audioPlayer.playing}');
        } catch (e, stackTrace) {
          Logger.error('🎵 AUDIO_DEBUG: play() FAILED: $e');
          Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
          rethrow;
        }

        Logger.info(
            '🎵 AUDIO_DEBUG: ===== PLAYBACK STARTED SUCCESSFULLY =====');
      } finally {
        _isPlayingStream = false;
        Logger.info('🎵 AUDIO_DEBUG: Set _isPlayingStream = false');
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

      if (_isPlayingStream) {
        Logger.info('🎵 FAILOVER: Stopping current stream for failover');
        await _audioPlayer.stop();
        _isPlayingStream = false;
      }

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

        Logger.info('🎵 FAILOVER: Creating audio source from local file...');
        final audioSource = AudioSource.file(
          filePath,
          tag: {
            'title': _currentConfig!.title ?? 'Failover Track',
            'artist': _currentConfig!.description ?? '',
          },
        );

        Logger.info('🎵 FAILOVER: Setting audio source...');
        await _audioPlayer
            .setAudioSource(
          audioSource,
          initialPosition: Duration.zero,
          preload: true,
        )
            .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            Logger.error('🎵 FAILOVER: setAudioSource timed out');
            throw TimeoutException('setAudioSource operation timed out');
          },
        );

        Logger.info('🎵 FAILOVER: Setting volume...');
        await _audioPlayer.setVolume(_currentVolume);

        Logger.info('🎵 FAILOVER: Starting playback...');
        await _audioPlayer.play().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            Logger.error('🎵 FAILOVER: play() timed out');
            throw TimeoutException('play operation timed out');
          },
        );

        Logger.info(
            '🎵 FAILOVER: ===== LOCAL FILE PLAYBACK STARTED SUCCESSFULLY =====');
      } finally {
        _isPlayingStream = false;
      }
    });
  }

  @override
  Future<Result<void>> pause() async {
    return tryResultAsync(() async {
      await _audioPlayer.pause();
      Logger.info('Playback paused');
    });
  }

  @override
  Future<Result<void>> resume() async {
    return tryResultAsync(() async {
      await _audioPlayer.play();
      Logger.info('Playback resumed');
    });
  }

  @override
  Future<Result<void>> stop() async {
    return tryResultAsync(() async {
      _cancelTimeouts();
      await _audioPlayer.stop();

      _currentConfig = null;
      _streamStartTime = null;
      _isPlayingStream = false;
      _currentStreamUrl = null;

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

  Future<Duration> _calculateOptimalPrebufferDelay() async {
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

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    Logger.info('Disposing AudioService');

    _cancelTimeouts();
    _hangDetectionTimer?.cancel();

    await _playerStateSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _bufferSubscription?.cancel();
    await _currentIndexSubscription?.cancel();
    await _connectivitySubscription?.cancel();

    await _audioPlayer.dispose();

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
