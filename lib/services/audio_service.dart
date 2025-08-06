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

    // Configure player with enhanced buffering settings for radio streams
    final configuration = PlayerConfiguration(
      // Enhanced buffer settings for stable live radio streams
      bufferSize: AudioConfig.androidTargetBufferBytes,

      // Optimize for live streaming
      logLevel: MPVLogLevel.info,

      // Enable additional protocol support for radio streams
      protocolWhitelist: [
        'udp',
        'rtp',
        'tcp',
        'tls',
        'data',
        'file',
        'http',
        'https',
        'crypto',
        'hls',
        'dash'
      ],
    );

    _audioPlayer = Player(configuration: configuration);

    Logger.info(
        '🎵 INIT_DEBUG: AudioPlayer instance created with buffer config');
    Logger.info(
        '🎵 INIT_DEBUG: Buffer size: ${AudioConfig.androidTargetBufferBytes ~/ (1024 * 1024)}MB');
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
        quality: ConnectionQuality.fromBufferSize(_currentBufferSize),
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

    Logger.info('🎵 BUFFER_DEBUG: ===== BUFFER UPDATE =====');
    Logger.info(
        '🎵 BUFFER_DEBUG: Current position: ${currentPosition.inSeconds}s');
    Logger.info(
        '🎵 BUFFER_DEBUG: Buffered position: ${bufferedPosition.inSeconds}s');
    Logger.info(
        '🎵 BUFFER_DEBUG: Raw buffer ahead: ${rawBufferAhead.inSeconds}s');

    // Optimized buffer calculation for stable Icecast2 live streams
    final timePlaying = _streamStartTime != null
        ? DateTime.now().difference(_streamStartTime!)
        : Duration.zero;

    // For live radio streams, use conservative buffer estimation
    // Prevents over-buffering which can cause playback issues
    if (rawBufferAhead.inSeconds <= 2) {
      Logger.info(
          '🎵 BUFFER_DEBUG: Live stream detected - using conservative estimation');
      Logger.info('🎵 BUFFER_DEBUG: Time playing: ${timePlaying.inSeconds}s');

      // Use conservative buffer calculation for stability
      final baseBufferSeconds = _getExpectedCacheBuffer();

      if (timePlaying.inSeconds < 2) {
        // Quick startup phase: very minimal buffer
        _currentBufferSize =
            Duration(seconds: timePlaying.inSeconds.clamp(0, 2));
        Logger.info(
            '🎵 BUFFER_DEBUG: Quick startup: ${_currentBufferSize.inSeconds}s');
      } else if (timePlaying.inSeconds < 8) {
        // Growing phase: gradual buffer build (like Howl.js)
        final realBuffer = (timePlaying.inSeconds - 2).clamp(0, 6) + 2;
        _currentBufferSize = Duration(seconds: realBuffer);
        Logger.info(
            '🎵 BUFFER_DEBUG: Building buffer: ${_currentBufferSize.inSeconds}s (${timePlaying.inSeconds}s playing)');
      } else {
        // Stable phase: maintain conservative buffer
        _currentBufferSize = Duration(seconds: baseBufferSeconds.clamp(4, 10));
        Logger.info(
            '🎵 BUFFER_DEBUG: Stable conservative buffer: ${_currentBufferSize.inSeconds}s');
      }
    } else {
      // Non-live stream: use actual position difference
      _currentBufferSize =
          Duration(seconds: rawBufferAhead.inSeconds.clamp(0, 15));
      Logger.info(
          '🎵 BUFFER_DEBUG: Non-live stream buffer: ${_currentBufferSize.inSeconds}s');
    }

    Logger.info(
        '🎵 BUFFER_DEBUG: Final buffer size: ${_currentBufferSize.inSeconds}s');
    _lastBufferUpdate = DateTime.now();

    // Update current state if it includes buffer info
    if (_currentState case AudioStatePlaying playing) {
      final quality = ConnectionQuality.fromBufferSize(_currentBufferSize);
      final newState =
          playing.copyWith(bufferSize: _currentBufferSize, quality: quality);

      Logger.info(
          '🎵 BUFFER_DEBUG: Before update - playing.bufferSize: ${playing.bufferSize.inSeconds}s');
      Logger.info(
          '🎵 BUFFER_DEBUG: After copyWith - newState.bufferSize: ${newState.bufferSize.inSeconds}s');
      Logger.info(
          '🎵 BUFFER_DEBUG: About to emit state with buffer: ${newState.bufferSize.inSeconds}s');

      _currentState = newState;
      _stateController.add(_currentState);

      Logger.info(
          '🎵 BUFFER_DEBUG: State emitted - _currentState.bufferSize: ${(_currentState as AudioStatePlaying).bufferSize.inSeconds}s');
    } else if (_currentState case AudioStateBuffering buffering) {
      _currentState = buffering.copyWith(bufferSize: _currentBufferSize);
      Logger.info(
          '🎵 BUFFER_DEBUG: Updated AudioStateBuffering with buffer: ${_currentBufferSize.inSeconds}s');
      _stateController.add(_currentState);
    } else {
      Logger.warning(
          '🎵 BUFFER_DEBUG: Current state is not Playing or Buffering: ${_currentState.runtimeType}');
    }
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
        // Get adaptive cache settings based on current network conditions
        final adaptiveSettings = _getAdaptiveCacheSettings();

        final media = Media(
          config.streamUrl,
          httpHeaders: AudioConfig.getStreamingHeaders(),
          // Optimized MPV options specifically for Icecast2 live radio streams
          extras: {
            // Adaptive cache settings based on network conditions
            ...adaptiveSettings,

            // Critical MPV cache optimizations for live stream stability
            'cache-backbuffer': '3', // Reduced back buffer for live streams
            'cache-on-disk': 'no', // Memory-only cache for live streams
            'cache-pause':
                'no', // Never pause on buffer underrun - critical for live
            'cache-pause-restart': 'no', // Don't restart cache on pause

            // Demuxer optimizations for Icecast2 MP3/AAC streams
            'demuxer-thread': 'yes', // Separate demuxing thread
            'demuxer-lavf-analyzeduration':
                '2000000', // 2s analysis - faster startup
            'demuxer-lavf-probesize':
                '1048576', // 1MB probe - sufficient for radio
            'demuxer-lavf-format': 'mp3,aac,ogg', // Expected Icecast2 formats
            'demuxer-readahead-secs': '3.0', // Conservative readahead

            // Enhanced network settings for Icecast2 reliability
            'network-timeout': '15', // Increased timeout for stability
            'stream-lavf-o':
                'timeout=15000000,reconnect=1,reconnect_streamed=1,reconnect_delay_max=1,reconnect_at_eof=1,stimeout=8000000,multiple_requests=1', // Optimized Icecast2 reconnection
            'demuxer-lavf-o':
                'timeout=10000000,reconnect=1,reconnect_streamed=1', // Additional demuxer reconnection
            'user-agent': AudioConfig.userAgent,

            // Audio processing optimized for continuous playback
            'audio-buffer': '0.2', // Reduced buffer latency for live feel
            'audio-stream-silence': 'yes', // Handle Icecast2 silence gaps
            'audio-samplerate': '44100', // Standard radio sample rate
            'audio-channels': 'auto', // Auto-detect channel layout
            'audio-format': 's16', // Stable format for live streams

            // Icecast2-specific HTTP optimizations
            'http-header-fields':
                'Connection: keep-alive,Accept: */*,Icy-MetaData: 1,Cache-Control: no-cache', // Enhanced Icecast2 headers
            'stream-record': '', // No recording
            'stream-dump': '', // No dumping

            // Fast connection establishment
            'stream-fast-open': 'yes', // Quick stream opening
            'tls-verify': 'no', // Skip TLS verification for speed

            // Live stream behavior
            'vid': 'no', // Audio only
            'video': 'no', // Disable video processing
            'untimed': 'no', // Maintain timing
            'hr-seek': 'no', // No seeking in live streams
            'save-position-on-quit': 'no', // No position saving

            // Connection persistence
            'keep-open': 'yes', // Maintain connection
            'keep-open-pause': 'no', // Don't pause on keep-open
            'idle': 'no', // No idle state
            'loop-playlist': 'no', // No looping

            // Performance and stability
            'hwdec': 'no', // Software decoding for stability
            'vo': 'null', // No video output
            'really-quiet': 'no', // Keep essential logging
            'msg-level': 'all=warn', // Reduce log verbosity

            // Critical: Prevent MPV from being too aggressive with buffering
            'force-seekable': 'no', // Don't force seekability on live streams
            'stream-cache': 'yes', // Enable stream caching
            'stream-cache-size': '2048', // 2MB stream cache
          },
        );
        Logger.info(
            '🎵 AUDIO_DEBUG: Media created with adaptive cache options:');
        Logger.info(
            '🎵 AUDIO_DEBUG: - cache-secs: ${adaptiveSettings['cache-secs']}');
        Logger.info(
            '🎵 AUDIO_DEBUG: - demuxer-readahead-secs: ${adaptiveSettings['demuxer-readahead-secs']}');
        Logger.info(
            '🎵 AUDIO_DEBUG: - stream-buffer-size: ${adaptiveSettings['stream-buffer-size']}');
        Logger.info(
            '🎵 AUDIO_DEBUG: - network-type: ${_networkState.type.displayName}');
        Logger.info(
            '🎵 AUDIO_DEBUG: - expected-buffer: ${_getExpectedCacheBuffer()}s');
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

          // Minimal delay for all network types - prioritize fast startup
          if (responseTime < 100) {
            // Fast network - minimal delay like Howl.js
            Logger.info(
                '🌐 NETWORK: Fast network detected - minimal pre-buffer');
            return const Duration(seconds: 1);
          } else if (responseTime < 500) {
            // Medium network - short delay
            Logger.info(
                '🌐 NETWORK: Medium network detected - short pre-buffer');
            return const Duration(seconds: 2);
          } else {
            // Slow network - moderate delay
            Logger.info(
                '🌐 NETWORK: Slow network detected - moderate pre-buffer');
            return const Duration(seconds: 3);
          }
        }
      } catch (e) {
        Logger.warning('🌐 NETWORK: Connectivity test failed: $e');
      }
    } catch (e) {
      Logger.warning('🌐 NETWORK: Pre-buffer calculation failed: $e');
    }

    // Default fallback - minimal for fast startup
    Logger.info('🌐 NETWORK: Using minimal default pre-buffer delay');
    return const Duration(seconds: 2);
  }

  /// Get adaptive cache settings based on network conditions
  Map<String, String> _getAdaptiveCacheSettings() {
    // Base settings optimized for Icecast2 stability
    final settings = <String, String>{
      // Core cache settings - balanced for live radio stability
      'cache': 'yes',
      'cache-secs':
          '8', // Reduced cache for live streams - prevents over-buffering
      'cache-pause': 'no', // CRITICAL: Never pause on buffer underrun
      'cache-pause-wait': '0.1', // Minimal wait before resume
      'cache-pause-initial': 'no', // Start playing immediately
      'cache-seek-min': '128', // Minimal seek cache (128KB)

      // Stream buffer optimized for Icecast2 stability
      'stream-buffer-size': '131072', // 128KB - prevents memory pressure
      'demuxer-cache-wait': 'no', // Don't wait for cache fill
      'demuxer-readahead-secs': '2.0', // Conservative readahead
      'demuxer-max-bytes': '1048576', // 1MB demuxer buffer
      'demuxer-seekable-cache': 'no', // Disable for live streams
    };

    // Adapt based on network conditions - conservative approach for stability
    if (_networkState.isConnected) {
      switch (_networkState.type) {
        case ConnectionType.wifi:
          // WiFi - moderate buffers to prevent over-buffering
          Logger.info(
              '🌐 ADAPTIVE: WiFi detected - using moderate buffers for stability');
          settings['cache-secs'] = '10'; // Conservative for live streams
          settings['demuxer-readahead-secs'] = '3.0'; // Moderate readahead
          break;

        case ConnectionType.mobile:
          // Mobile data - minimal buffers for efficiency
          Logger.info(
              '🌐 ADAPTIVE: Mobile data detected - using minimal buffers');
          settings['cache-secs'] = '6'; // Minimal cache for mobile
          settings['demuxer-readahead-secs'] = '2.0'; // Conservative readahead
          break;

        case ConnectionType.ethernet:
          // Ethernet - slightly larger but not excessive
          Logger.info('🌐 ADAPTIVE: Ethernet detected - using stable buffers');
          settings['cache-secs'] = '12'; // Stable cache for ethernet
          settings['demuxer-readahead-secs'] = '4.0'; // Moderate readahead
          break;

        default:
          Logger.info(
              '🌐 ADAPTIVE: Unknown connection - using conservative defaults');
      }
    } else {
      // No network - absolute minimal settings
      Logger.warning(
          '🌐 ADAPTIVE: No network detected - using minimal settings');
      settings['cache-secs'] = '4';
      settings['demuxer-readahead-secs'] = '1.0';
    }

    return settings;
  }

  /// Get expected cache buffer size based on current network settings
  int _getExpectedCacheBuffer() {
    // Return conservative buffer sizes optimized for live stream stability
    if (_networkState.isConnected) {
      switch (_networkState.type) {
        case ConnectionType.wifi:
          return 10; // Moderate buffer for WiFi stability
        case ConnectionType.ethernet:
          return 12; // Slightly larger for ethernet
        case ConnectionType.mobile:
          return 6; // Conservative for mobile data
        default:
          return 8; // Conservative default
      }
    } else {
      return 4; // Minimal for offline scenarios
    }
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
    ConnectionQuality? quality,
    PlaybackStats? stats,
  }) =>
      AudioStatePlaying(
        config: config ?? this.config,
        position: position ?? this.position,
        bufferSize: bufferSize ?? this.bufferSize,
        quality: quality ?? this.quality,
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
