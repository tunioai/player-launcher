import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../core/result.dart';
import '../core/dependency_injection.dart';
import '../core/audio_state.dart';
import '../models/stream_config.dart';
import '../utils/logger.dart';
import '../utils/audio_config.dart';

/// Interface for audio service
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

/// Enhanced AudioService with proper error handling and clean architecture
final class EnhancedAudioService implements IAudioService {
  late final Player _audioPlayer;

  // State management
  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<NetworkState> _networkController =
      StreamController<NetworkState>.broadcast();

  AudioState _currentState = const AudioStateIdle();
  NetworkState _networkState =
      const NetworkState(isConnected: false, type: ConnectionType.unknown);

  // Subscriptions
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration>? _bufferSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Current stream tracking
  StreamConfig? _currentConfig;

  double _currentVolume = 1.0;

  // Statistics
  PlaybackStats _playbackStats = const PlaybackStats();
  DateTime? _streamStartTime;
  DateTime? _lastBufferUpdate;
  Duration _currentBufferSize = Duration.zero;

  // Timeout management
  Timer? _loadingTimeoutTimer;
  Timer? _hangDetectionTimer;

  // Concurrency control
  final Completer<void> _initializationCompleter = Completer<void>();
  bool _isInitialized = false;
  bool _isDisposed = false;
  bool _isPlayingStream = false; // Protection against multiple playStream calls
  String?
      _currentStreamUrl; // Track current stream URL to prevent duplicate connections

  // Configuration - optimized for live stream stability
  static const Duration _loadingTimeout =
      Duration(seconds: 30); // Increased for live streams
  static const Duration _hangDetectionInterval =
      Duration(seconds: 15); // Less aggressive checking
  static const Duration _maxHangTime =
      Duration(seconds: 45); // More tolerance for live streams

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

    // Optimized configuration for AAC live streams
    final configuration = PlayerConfiguration(
      // Increased buffer for AAC stream stability
      bufferSize: 4 * 1024 * 1024, // 4MB for better AAC stability

      // Enable async mode for improved performance (media_kit 1.2.0+)
      async: true,

      // Reduced logging for stability
      logLevel: MPVLogLevel.warn,

      // Extended protocol support for various stream types
      protocolWhitelist: [
        'http',
        'https',
        'tcp',
        'tls',
        'rtp',
        'rtsp',
      ],
    );

    _audioPlayer = Player(configuration: configuration);

    Logger.info(
        '🎵 INIT_DEBUG: AudioPlayer instance created with AAC-optimized config');
    Logger.info('🎵 INIT_DEBUG: Buffer size: 4MB, Async mode: enabled');
    Logger.info(
        '🎵 INIT_DEBUG: Initial player state: ${_audioPlayer.state.playing}');
    Logger.info('🎵 INIT_DEBUG: ===== AUDIO PLAYER INITIALIZED =====');
  }

  void _setupSubscriptions() {
    // Player state monitoring
    _playingSubscription = _audioPlayer.stream.playing.listen(
      _handlePlayingStateChange,
      onError: _handlePlayerError,
    );

    // Position monitoring with hang detection
    _positionSubscription = _audioPlayer.stream.position.listen(
      _handlePositionUpdate,
      onError: (error) => Logger.error('Position stream error: $error'),
    );

    // Buffer monitoring
    _bufferSubscription = _audioPlayer.stream.buffer.listen(
      _handleBufferUpdate,
      onError: (error) => Logger.error('Buffer stream error: $error'),
    );

    // Completed event monitoring
    _completedSubscription = _audioPlayer.stream.completed.listen(
      _handleTrackCompleted,
      onError: (error) => Logger.error('Completed stream error: $error'),
    );

    // Network monitoring
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
          _handleConnectivityChange,
          onError: (error) => Logger.error('Connectivity stream error: $error'),
        );

    // Check initial network state
    _checkInitialNetworkState();
  }

  Future<void> _checkInitialNetworkState() async {
    try {
      // Wait a bit to let the connectivity plugin initialize properly
      await Future.delayed(const Duration(milliseconds: 500));
      final results = await Connectivity().checkConnectivity();

      // Double-check with actual internet connectivity test
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
      // Start with unknown state instead of disconnected
      _networkState = _networkState.copyWith(
        isConnected: true, // Assume connected to avoid false negatives
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
      return true; // Assume connected to avoid false negatives
    }
  }

  void _handlePlayingStateChange(bool isPlaying) {
    Logger.info('🎵 STATE_DEBUG: ===== PLAYER STATE CHANGED =====');
    Logger.info('🎵 STATE_DEBUG: Playing: $isPlaying');
    Logger.info(
        '🎵 STATE_DEBUG: Player position: ${_audioPlayer.state.position}');
    Logger.info(
        '🎵 STATE_DEBUG: Player duration: ${_audioPlayer.state.duration}');

    final newAudioState = _computeAudioState(isPlaying);
    Logger.info(
        '🎵 STATE_DEBUG: Computed new audio state: ${newAudioState.runtimeType}');

    if (_currentState.runtimeType != newAudioState.runtimeType) {
      Logger.info(
          '🎵 STATE_DEBUG: Audio state transition: ${_currentState.runtimeType} → ${newAudioState.runtimeType}');

      // Handle state-specific logic
      switch (newAudioState) {
        case AudioStateLoading():
          Logger.info('🎵 STATE_DEBUG: Starting loading timeout...');
          _startLoadingTimeout();

        case AudioStatePlaying():
          Logger.info(
              '🎵 STATE_DEBUG: Canceling timeouts and updating stats...');
          _cancelTimeouts();
          _updatePlaybackStats();

          // If we're playing, we must have network connectivity
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

  AudioState _computeAudioState(bool isPlaying) {
    if (_currentConfig == null) return const AudioStateIdle();

    final position = _audioPlayer.state.position;

    // Simple state logic: if playing -> Playing, otherwise -> Loading/Paused based on position
    if (isPlaying) {
      return AudioStatePlaying(
        config: _currentConfig!,
        position: position,
        bufferSize: _currentBufferSize,
        stats: _playbackStats,
      );
    }

    // If not playing but we have position, consider it paused
    if (position.inMilliseconds > 0) {
      return AudioStatePaused(
        config: _currentConfig!,
        position: position,
        bufferSize: _currentBufferSize,
      );
    }

    // Otherwise, still loading
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
    // Simple position update - no track end detection for live streams
    if (_currentState is AudioStatePlaying) {
      final playing = _currentState as AudioStatePlaying;
      _currentState = playing.copyWith(position: position);
      _stateController.add(_currentState);
    }
  }

  void _handleBufferUpdate(Duration bufferedPosition) {
    final currentPosition = _audioPlayer.state.position;
    final rawBufferAhead = bufferedPosition - currentPosition;

    // Optimized buffer calculation for AAC live streams
    final timePlaying = _streamStartTime != null
        ? DateTime.now().difference(_streamStartTime!)
        : Duration.zero;

    // For AAC radio streams, use slightly larger buffer for stability
    // AAC streams need more buffer to prevent drops
    if (rawBufferAhead.inSeconds <= 2) {
      // AAC streams benefit from slightly larger buffers
      if (timePlaying.inSeconds < 5) {
        _currentBufferSize = Duration(seconds: 3); // Initial buffer for AAC
      } else {
        _currentBufferSize = Duration(seconds: 5); // Stable buffer for AAC
      }
    } else {
      // Use actual buffer but with higher cap for AAC stability
      _currentBufferSize =
          Duration(seconds: rawBufferAhead.inSeconds.clamp(0, 8));
    }

    _lastBufferUpdate = DateTime.now();

    // Update current state if it includes buffer info
    if (_currentState case AudioStatePlaying playing) {
      final newState = playing.copyWith(bufferSize: _currentBufferSize);

      _currentState = newState;
      _stateController.add(_currentState);
    } else if (_currentState case AudioStateBuffering buffering) {
      _currentState = buffering.copyWith(bufferSize: _currentBufferSize);
      _stateController.add(_currentState);
    } else {}
  }

  void _handleTrackCompleted(bool completed) {
    // For live streams, completion events are rare and should be handled simply
    if (completed && _currentConfig != null) {
      Logger.info('Track completed - transitioning to idle');
      _currentState = const AudioStateIdle();
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

    // Smart network detection: if we're playing audio successfully, we must be connected
    final isActuallyConnected = hasConnection || _currentState.isPlaying;

    // Only update network state if it actually changed to avoid false positives
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
      // Update only connection type without triggering state change
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
    Logger.error(
        '🎵 ERROR_DEBUG: Current player state: ${_audioPlayer.state.playing}');

    // Enhanced HTTP error logging
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

    // Check for loading/buffering hangs
    if (_currentState case AudioStateLoading loading) {
      if (loading.elapsed > _maxHangTime) {
        Logger.error('Detected loading hang: ${loading.elapsed.inSeconds}s');
        _handlePlayerError(
            TimeoutException('Loading hang detected', _maxHangTime));
      }
    } else if (_currentState case AudioStateBuffering buffering) {
      if (buffering.elapsed > _maxHangTime) {
        Logger.error(
            'Detected buffering hang: ${buffering.elapsed.inSeconds}s');
        _handlePlayerError(
            TimeoutException('Buffering hang detected', _maxHangTime));
      }
    }

    // Check for buffer update hangs - but only if we're not actively playing
    // Live streams may not update buffer position regularly while playing normally
    if (_lastBufferUpdate != null &&
        _currentState.isPlaying &&
        now.difference(_lastBufferUpdate!) > Duration(minutes: 2) &&
        _audioPlayer.state.position.inSeconds == 0) {
      // Only trigger hang detection if position is also stuck at 0
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
      Logger.info('🎵 AUDIO_DEBUG: ===== STARTING PLAYBOOK =====');
      Logger.info('🎵 AUDIO_DEBUG: Title: ${config.title}');
      Logger.info('🎵 AUDIO_DEBUG: Stream URL: ${config.streamUrl}');
      Logger.info('🎵 AUDIO_DEBUG: Volume: ${config.volume}');
      Logger.info(
          '🎵 AUDIO_DEBUG: Current _isPlayingStream: $_isPlayingStream');
      Logger.info('🎵 AUDIO_DEBUG: Current stream URL: $_currentStreamUrl');

      // Check if we're already playing the same stream
      if (_isPlayingStream && _currentStreamUrl == config.streamUrl) {
        Logger.warning(
            '🎵 AUDIO_DEBUG: ⚠️ Already playing the same stream, ignoring duplicate call');
        return; // Simply ignore duplicate calls for the same stream
      }

      // If we're playing a different stream, stop the current one first
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

        // Minimal pre-buffering for faster startup (like Howl.js)
        final prebufferDelay = await _calculateOptimalPrebufferDelay();
        Logger.info(
            '🎵 AUDIO_DEBUG: Pre-buffering for ${prebufferDelay.inSeconds}s for stable connection...');
        await Future.delayed(prebufferDelay);

        // Open media with media_kit
        Logger.info('🎵 AUDIO_DEBUG: Opening media source...');
        // Get simple cache settings for radio streaming

        final media = Media(
          config.streamUrl,
          httpHeaders: AudioConfig.getStreamingHeaders(),
          // Optimized MPV configuration for AAC live streaming
          extras: {
            // Enhanced cache settings for AAC streams
            'cache': 'yes',
            'cache-secs': '10', // Increased cache for AAC stability
            'cache-pause': 'no', // Never pause on underrun
            'cache-on-disk': 'no', // Memory cache only
            'demuxer-max-bytes': '10MiB', // Larger demuxer buffer for AAC
            'demuxer-max-back-bytes': '5MiB',

            // AAC-specific optimizations
            'audio-samplerate': '44100', // Match your stream's sample rate
            'audio-channels': 'stereo', // Force stereo for consistency
            'audio-format': 'f32', // Float32 for better quality
            'audio-buffer': '1.0', // 1 second audio buffer

            // Enhanced network settings
            'network-timeout': '30', // Increased timeout for stability
            'user-agent': AudioConfig.userAgent,
            'stream-lavf-o':
                'timeout=30000000,reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',

            // Audio-only optimizations
            'vid': 'no', // Audio only
            'video': 'no', // Disable video processing
            'vo': 'null', // No video output

            // Stream reliability
            'keep-open': 'yes', // Maintain connection
            'hwdec': 'no', // Software decoding for stability
            'hr-seek': 'no', // Disable precise seeking for streams
            'cache-seek-min': '1024', // Minimum seek size

            // Platform-specific (Android)
            'ao': 'audiotrack', // Use Android AudioTrack
            'audio-fallback-to-null': 'yes', // Fallback on errors

            // Reduce logging
            'msg-level': 'all=warn',
          },
        );
        Logger.info(
            '🎵 AUDIO_DEBUG: Media created with simplified cache settings');
        Logger.info('🎵 AUDIO_DEBUG: Stream URL: ${config.streamUrl}');

        // Open media source with extended timeout for live streams
        Logger.info('🎵 AUDIO_DEBUG: About to call open...');
        Logger.info(
            '🎵 AUDIO_DEBUG: Current player state: ${_audioPlayer.state.playing}');
        try {
          final setSourceStartTime = DateTime.now();
          await _audioPlayer.open(media).timeout(
            const Duration(seconds: 25), // Extended timeout for live streams
            onTimeout: () {
              final elapsed = DateTime.now().difference(setSourceStartTime);
              Logger.error(
                  '🎵 AUDIO_DEBUG: open timed out after ${elapsed.inSeconds}s');
              throw TimeoutException('open operation timed out');
            },
          );
          final setSourceDuration =
              DateTime.now().difference(setSourceStartTime);
          Logger.info(
              '🎵 AUDIO_DEBUG: open completed successfully in ${setSourceDuration.inMilliseconds}ms');
          Logger.info(
              '🎵 AUDIO_DEBUG: Player state after open: ${_audioPlayer.state.playing}');
        } catch (e, stackTrace) {
          Logger.error('🎵 AUDIO_DEBUG: open FAILED: $e');
          Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
          rethrow;
        }

        // Set volume
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

        // Start playback with timeout to prevent hanging
        Logger.info('🎵 AUDIO_DEBUG: About to call play()...');
        Logger.info(
            '🎵 AUDIO_DEBUG: Player state before play(): ${_audioPlayer.state.playing}');
        Logger.info(
            '🎵 AUDIO_DEBUG: Player position before play(): ${_audioPlayer.state.position}');
        Logger.info(
            '🎵 AUDIO_DEBUG: Player duration before play(): ${_audioPlayer.state.duration}');
        try {
          final playStartTime = DateTime.now();
          await _audioPlayer.play().timeout(
            const Duration(seconds: 10), // Timeout for play operation
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
              '🎵 AUDIO_DEBUG: Player state after play(): ${_audioPlayer.state.playing}');
          Logger.info(
              '🎵 AUDIO_DEBUG: Player position after play(): ${_audioPlayer.state.position}');
        } catch (e, stackTrace) {
          Logger.error('🎵 AUDIO_DEBUG: play() FAILED: $e');
          Logger.error('🎵 AUDIO_DEBUG: Stack trace: $stackTrace');
          rethrow;
        }

        // Track stream URL via config
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

      // Check if file exists
      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Local file not found: $filePath');
      }

      // If we're already playing something, stop it first
      if (_isPlayingStream) {
        Logger.info('🎵 FAILOVER: Stopping current stream for failover');
        await _audioPlayer.stop();
        _isPlayingStream = false;
      }

      _isPlayingStream = true;
      _currentStreamUrl =
          null; // Clear stream URL since we're playing local file

      try {
        _streamStartTime = DateTime.now();

        // Create mock config for local file
        _currentConfig = originalConfig ??
            StreamConfig(
              streamUrl: filePath,
              title: 'Failover Track',
              description: 'Playing from local cache',
              volume: _currentVolume,
            );

        Logger.info('🎵 FAILOVER: Creating media from local file...');
        final media = Media('file://$filePath');

        // Open media source
        Logger.info('🎵 FAILOVER: Opening media...');
        await _audioPlayer.open(media).timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            Logger.error('🎵 FAILOVER: open timed out');
            throw TimeoutException('open operation timed out');
          },
        );

        // Set volume
        Logger.info('🎵 FAILOVER: Setting volume...');
        await _audioPlayer
            .setVolume(_currentVolume * 100); // media_kit uses 0-100 scale

        // Start playback
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
      // Clear stream tracking
      _streamStartTime = null;
      _isPlayingStream = false; // Reset flag on stop
      _currentStreamUrl = null; // Clear stream URL tracking

      _currentState = const AudioStateIdle();
      _stateController.add(_currentState);

      Logger.info('Playback stopped');
    });
  }

  @override
  Future<Result<void>> setVolume(double volume) async {
    return tryResultAsync(() async {
      _currentVolume = volume.clamp(0.0, 1.0);
      await _audioPlayer
          .setVolume(_currentVolume * 100); // media_kit uses 0-100 scale
    });
  }

  /// Calculate optimal pre-buffer delay based on network conditions
  Future<Duration> _calculateOptimalPrebufferDelay() async {
    try {
      // Test network speed by measuring connectivity
      final stopwatch = Stopwatch()..start();

      // Quick connectivity test to google.com (already used in the codebase)
      try {
        final result = await InternetAddress.lookup('google.com')
            .timeout(const Duration(seconds: 2));
        stopwatch.stop();

        if (result.isNotEmpty) {
          final responseTime = stopwatch.elapsedMilliseconds;
          Logger.info('🌐 NETWORK: Connectivity test: ${responseTime}ms');

          // AAC streams need slightly more pre-buffer time for stability
          if (responseTime < 100) {
            // Fast network - moderate delay for AAC
            Logger.info(
                '🌐 NETWORK: Fast network detected - AAC pre-buffer 2s');
            return const Duration(seconds: 2);
          } else if (responseTime < 500) {
            // Medium network - standard delay for AAC
            Logger.info(
                '🌐 NETWORK: Medium network detected - AAC pre-buffer 3s');
            return const Duration(seconds: 3);
          } else {
            // Slow network - extended delay for AAC
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

    // Default fallback - moderate for AAC stability
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

    await _playingSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _bufferSubscription?.cancel();
    await _completedSubscription?.cancel();
    await _connectivitySubscription?.cancel();

    await _audioPlayer.dispose();

    await _stateController.close();
    await _networkController.close();

    Logger.info('AudioService disposed');
  }
}

// Extension for copying states (since we don't have Freezed)
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
