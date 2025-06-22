import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/stream_config.dart';
import '../utils/logger.dart';
import '../utils/audio_config.dart';
import '../utils/connection_monitor.dart';

enum AudioState {
  idle,
  loading,
  playing,
  paused,
  buffering,
  error,
}

class AudioService {
  static AudioService? _instance;

  late AudioPlayer _audioPlayer;
  late AudioSession _audioSession;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  StreamSubscription<Duration?>? _positionSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  String? _currentStreamUrl;
  double _currentVolume = 1.0;
  DateTime? _networkLostTime; // Track when network was lost
  bool _isNetworkConnected = true; // Track network state

  // MUTEX: Prevent concurrent playStream calls
  bool _isPlayStreamInProgress = false;

  // CONNECTION MONITORING: Track active connections
  String? _currentConnectionId;

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _connectionQualityController =
      StreamController<String>.broadcast();

  AudioService._();

  static Future<AudioService> getInstance() async {
    _instance ??= AudioService._();
    await _instance!._initialize();
    return _instance!;
  }

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<Duration> get bufferStream => _bufferController.stream;
  Stream<String> get connectionQualityStream =>
      _connectionQualityController.stream;

  AudioState get currentState {
    // Check for loading state first
    if (_audioPlayer.processingState == ProcessingState.loading) {
      return AudioState.loading;
    }
    // Check for buffering state
    else if (_audioPlayer.processingState == ProcessingState.buffering) {
      return AudioState.buffering;
    }
    // Check if player thinks it's playing AND has a valid stream
    else if (_audioPlayer.playing &&
        _audioPlayer.processingState == ProcessingState.ready) {
      return AudioState.playing;
    }
    // Player might be "playing" but not ready - treat as buffering
    else if (_audioPlayer.playing &&
        _audioPlayer.processingState != ProcessingState.ready) {
      return AudioState.buffering;
    }
    // Player is ready but paused
    else if (_audioPlayer.processingState == ProcessingState.ready) {
      return AudioState.paused;
    }
    // All other cases
    else {
      return AudioState.idle;
    }
  }

  Future<void> _initialize() async {
    _audioSession = await AudioSession.instance;
    await _audioSession.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playback,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.allowBluetooth |
              AVAudioSessionCategoryOptions.defaultToSpeaker,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
      avAudioSessionRouteSharingPolicy:
          AVAudioSessionRouteSharingPolicy.defaultPolicy,
      avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.music,
        flags: AndroidAudioFlags.none,
        usage: AndroidAudioUsage.media,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      androidWillPauseWhenDucked: false,
    ));

    // EMERGENCY ROLLBACK: Using known working configuration
    final config = AudioConfig.getSimpleStreamingConfiguration();
    Logger.info(
        '🔧 AudioService: ROLLBACK to working simple config', 'AudioService');

    _audioPlayer = AudioPlayer(
      userAgent: AudioConfig.userAgent,
      useProxyForRequestHeaders: true,
      audioLoadConfiguration: config,
    );

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      final currentAudioState = currentState;
      Logger.debug(
          '🎵 STATE_DEBUG: Player state changed to ${state.processingState}, playing: ${state.playing}',
          'AudioService');
      Logger.debug('🎵 STATE_DEBUG: Current audio state: $currentAudioState',
          'AudioService');
      Logger.debug(
          '🎵 STATE_DEBUG: Timestamp: ${DateTime.now().toIso8601String()}',
          'AudioService');
      Logger.debug(
          '🎵 STATE_DEBUG: Player position: ${_audioPlayer.position.inSeconds}s',
          'AudioService');
      Logger.debug(
          '🎵 STATE_DEBUG: Player buffered position: ${_audioPlayer.bufferedPosition.inSeconds}s',
          'AudioService');
      Logger.debug(
          '🎵 STATE_DEBUG: Player duration: ${_audioPlayer.duration?.inSeconds ?? 'null'}s',
          'AudioService');

      // Log detailed state analysis
      if (state.processingState == ProcessingState.loading) {
        Logger.warning(
            '🎵 STATE_DEBUG: LOADING state detected - stream is connecting',
            'AudioService');
      } else if (state.processingState == ProcessingState.buffering) {
        Logger.warning(
            '🎵 STATE_DEBUG: BUFFERING state detected - stream is buffering',
            'AudioService');
      } else if (state.processingState == ProcessingState.ready &&
          state.playing) {
        Logger.info(
            '🎵 STATE_DEBUG: PLAYING state detected - stream is playing successfully',
            'AudioService');
      } else if (state.processingState == ProcessingState.ready &&
          !state.playing) {
        Logger.warning(
            '🎵 STATE_DEBUG: PAUSED state detected - stream is ready but not playing',
            'AudioService');
      } else if (state.processingState == ProcessingState.idle) {
        Logger.warning('🎵 STATE_DEBUG: IDLE state detected - stream is idle',
            'AudioService');
      } else if (state.processingState == ProcessingState.completed) {
        Logger.warning(
            '🎵 STATE_DEBUG: COMPLETED state detected - stream ended',
            'AudioService');
      }

      // REAL BUFFER TEST: Check how long playback continues without network
      if (!_isNetworkConnected && _networkLostTime != null) {
        final timeSinceNetworkLoss =
            DateTime.now().difference(_networkLostTime!);
        if (state.playing) {
          Logger.info(
              '📊 BUFFER_DEBUG: Still playing ${timeSinceNetworkLoss.inSeconds}s after network loss (claimed buffer was showing ${_audioPlayer.bufferedPosition.inSeconds - _audioPlayer.position.inSeconds}s)',
              'AudioService');
        } else if (state.processingState == ProcessingState.buffering) {
          Logger.warning(
              '📊 BUFFER_DEBUG: Started buffering after ${timeSinceNetworkLoss.inSeconds}s without network (this is the REAL buffer size)',
              'AudioService');
        }
      }

      _stateController.add(currentAudioState);
      Logger.debug(
          '🎵 STATE_DEBUG: Broadcasted audio state: $currentAudioState',
          'AudioService');

      if (state.processingState == ProcessingState.completed) {
        Logger.debug('🎵 STATE_DEBUG: Stream completed, handling stream end',
            'AudioService');
        _handleStreamEnd();
      }
    });

    // Listen to error stream for enhanced error handling in just_audio 0.10.x
    _audioPlayer.errorStream.listen((error) {
      Logger.error('❌ AudioService: Player error: $error', 'AudioService');
      _handleError('Player error: ${error.message}');
    });

    _audioPlayer.playbackEventStream.listen((event) {
      if (event.processingState == ProcessingState.ready) {
        Logger.debug('🎵 AudioService: Stream ready', 'AudioService');
      }
    });

    // Additional position monitoring for live stream diagnostics
    _audioPlayer.positionStream.listen((position) {
      Logger.debug('⏱️ AudioService: Position update - ${position.inSeconds}s',
          'AudioService');
    });

    // Simplified buffer monitoring + connection quality for live streaming
    _audioPlayer.bufferedPositionStream.listen((bufferedPosition) {
      final currentPosition = _audioPlayer.position;
      final rawBufferAhead = bufferedPosition - currentPosition;

      // Simple buffer calculation - cap at 10s for live stream
      final bufferAhead =
          Duration(seconds: rawBufferAhead.inSeconds.clamp(0, 10));
      _bufferController.add(bufferAhead);

      // Connection quality assessment based on buffer behavior
      String connectionQuality = "Good";
      if (bufferAhead.inSeconds <= 2 && _audioPlayer.playing) {
        connectionQuality = "Poor";
      } else if (bufferAhead.inSeconds <= 5) {
        connectionQuality = "Fair";
      } else {
        connectionQuality = "Good";
      }

      _connectionQualityController.add(connectionQuality);

      // Enhanced buffer logging for debugging
      Logger.debug(
          '📊 BUFFER_DEBUG: Buffer ${bufferAhead.inSeconds}s, Quality: $connectionQuality',
          'AudioService');
      Logger.debug(
          '📊 BUFFER_DEBUG: Current pos: ${currentPosition.inSeconds}s, Buffered pos: ${bufferedPosition.inSeconds}s, Raw buffer: ${rawBufferAhead.inSeconds}s',
          'AudioService');
      Logger.debug(
          '📊 BUFFER_DEBUG: Player state: ${_audioPlayer.processingState}, Playing: ${_audioPlayer.playing}',
          'AudioService');
      Logger.debug(
          '📊 BUFFER_DEBUG: Timestamp: ${DateTime.now().toIso8601String()}',
          'AudioService');

      // Alert when buffer is critically low
      if (bufferAhead.inSeconds <= 1 && _audioPlayer.playing) {
        Logger.warning(
            '⚠️ BUFFER_DEBUG: CRITICAL - Buffer critically low (${bufferAhead.inSeconds}s) while playing!',
            'AudioService');
      }

      // Alert when buffer is zero (possible hang indicator)
      if (bufferAhead.inSeconds == 0) {
        Logger.error(
            '🚨 BUFFER_DEBUG: ZERO BUFFER detected! This might indicate a hang. Player state: ${_audioPlayer.processingState}, Playing: ${_audioPlayer.playing}',
            'AudioService');
      }
    });

    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      // Network monitoring only - RadioController handles reconnection logic
      final hasConnection = results.any((result) =>
          result == ConnectivityResult.mobile ||
          result == ConnectivityResult.wifi ||
          result == ConnectivityResult.ethernet);

      if (!hasConnection) {
        Logger.warning(
            '🌐 AudioService: Network connection lost', 'AudioService');
        _networkLostTime = DateTime.now();
        _isNetworkConnected = false;
      } else {
        if (_networkLostTime != null) {
          final totalOfflineTime = DateTime.now().difference(_networkLostTime!);
          Logger.info(
              '🌐 AudioService: Network connection restored after ${totalOfflineTime.inSeconds}s offline',
              'AudioService');
        } else {
          Logger.info(
              '🌐 AudioService: Network connection restored', 'AudioService');
        }
        _isNetworkConnected = true;
        _networkLostTime = null; // Reset timer
      }
    });
  }

  Future<void> playStream(StreamConfig config) async {
    // MUTEX: Prevent concurrent playStream calls
    if (_isPlayStreamInProgress) {
      Logger.warning(
          '⚠️ AUDIO_DEBUG: playStream already in progress, ignoring duplicate call',
          'AudioService');
      return;
    }

    _isPlayStreamInProgress = true;
    Logger.debug(
        '🎵 AUDIO_DEBUG: Starting playStream - mutex acquired', 'AudioService');

    try {
      Logger.debug(
          '🎵 AUDIO_DEBUG: Starting playStream with URL: ${config.streamUrl}',
          'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Stream title: ${config.title}', 'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Stream volume: ${config.volume}', 'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Current timestamp: ${DateTime.now().toIso8601String()}',
          'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Current player state: ${_audioPlayer.processingState}',
          'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Current player playing: ${_audioPlayer.playing}',
          'AudioService');

      _stateController.add(AudioState.loading);
      Logger.debug('🎵 AUDIO_DEBUG: Set state to LOADING', 'AudioService');

      if (_currentStreamUrl != config.streamUrl) {
        // PROPER CLEANUP: Ensure complete cleanup before new connection
        if (_currentStreamUrl != null) {
          Logger.info(
              '🔧 AUDIO_DEBUG: Stream URL changed from $_currentStreamUrl to $config.streamUrl, performing full cleanup',
              'AudioService');
          await _performFullCleanup();
        } else {
          Logger.info('🎵 AUDIO_DEBUG: First stream setup, no cleanup needed',
              'AudioService');
        }

        Logger.debug(
            '🎵 AUDIO_DEBUG: Creating audio source for URL: ${config.streamUrl}',
            'AudioService');
        final uri = Uri.parse(config.streamUrl);
        Logger.debug('🎵 AUDIO_DEBUG: Parsed URI: $uri', 'AudioService');
        Logger.debug(
            '🎵 AUDIO_DEBUG: URI scheme: ${uri.scheme}', 'AudioService');
        Logger.debug('🎵 AUDIO_DEBUG: URI host: ${uri.host}', 'AudioService');
        Logger.debug('🎵 AUDIO_DEBUG: URI path: ${uri.path}', 'AudioService');

        // SHORT DELAY: Allow network stack to fully close previous connection
        Logger.debug(
            '🎵 AUDIO_DEBUG: Waiting 500ms for network stack cleanup...',
            'AudioService');
        await Future.delayed(const Duration(milliseconds: 500));
        Logger.debug('🎵 AUDIO_DEBUG: Network stack cleanup delay completed',
            'AudioService');

        final audioSource = ProgressiveAudioSource(
          uri,
          headers: AudioConfig.getStreamingHeaders(),
        );
        Logger.debug(
            '🎵 AUDIO_DEBUG: Created ProgressiveAudioSource with headers: ${AudioConfig.getStreamingHeaders()}',
            'AudioService');

        // TRACK CONNECTION: Monitor new connection
        _currentConnectionId =
            ConnectionMonitor.trackConnection(config.streamUrl);
        Logger.debug(
            '🎵 AUDIO_DEBUG: Tracked connection with ID: $_currentConnectionId',
            'AudioService');

        Logger.debug(
            '🎵 AUDIO_DEBUG: About to set audio source with buffering config...',
            'AudioService');

        // Set audio source with preloading for better buffering
        final setSourceStartTime = DateTime.now();
        await _audioPlayer.setAudioSource(
          audioSource,
          initialPosition: Duration.zero,
          preload: true,
        );
        final setSourceDuration = DateTime.now().difference(setSourceStartTime);
        Logger.debug(
            '🎵 AUDIO_DEBUG: setAudioSource completed in ${setSourceDuration.inMilliseconds}ms',
            'AudioService');

        // CONFIGURABLE STARTUP DELAY: Use value from AudioConfig
        Logger.info(
            '🔄 AUDIO_DEBUG: Waiting ${AudioConfig.liveStreamStartupDelay.inSeconds} seconds for initial buffer',
            'AudioService');
        await Future.delayed(AudioConfig.liveStreamStartupDelay);
        Logger.debug(
            '🔄 AUDIO_DEBUG: Initial buffer delay completed', 'AudioService');

        _currentStreamUrl = config.streamUrl;
        Logger.debug(
            '🎵 AUDIO_DEBUG: Audio source set successfully with enhanced buffering',
            'AudioService');
      } else {
        Logger.debug(
            '🎵 AUDIO_DEBUG: Same stream URL, no need to recreate audio source',
            'AudioService');
      }

      Logger.debug('🎵 AUDIO_DEBUG: About to set volume to ${config.volume}...',
          'AudioService');
      await setVolume(config.volume);
      Logger.debug('🎵 AUDIO_DEBUG: Volume set successfully', 'AudioService');

      Logger.debug(
          '🎵 AUDIO_DEBUG: About to start playback...', 'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Player state before play(): ${_audioPlayer.processingState}',
          'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Player playing before play(): ${_audioPlayer.playing}',
          'AudioService');

      final playStartTime = DateTime.now();
      await _audioPlayer.play();
      final playDuration = DateTime.now().difference(playStartTime);

      Logger.debug(
          '🎵 AUDIO_DEBUG: play() call completed in ${playDuration.inMilliseconds}ms',
          'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Player state after play(): ${_audioPlayer.processingState}',
          'AudioService');
      Logger.debug(
          '🎵 AUDIO_DEBUG: Player playing after play(): ${_audioPlayer.playing}',
          'AudioService');

      Logger.debug(
          '🎵 AUDIO_DEBUG: Playback started successfully', 'AudioService');
    } catch (e) {
      Logger.error('❌ AUDIO_DEBUG: Error in playStream: $e', 'AudioService');
      Logger.error(
          '❌ AUDIO_DEBUG: Error type: ${e.runtimeType}', 'AudioService');
      Logger.error('❌ AUDIO_DEBUG: Error stack trace: ${StackTrace.current}',
          'AudioService');
      _handleError('Failed to play stream: $e');
    } finally {
      // ALWAYS release mutex
      _isPlayStreamInProgress = false;
      Logger.debug('🎵 AUDIO_DEBUG: playStream completed - mutex released',
          'AudioService');
    }
  }

  Future<void> _performFullCleanup() async {
    try {
      Logger.info('🔧 AudioService: Performing full cleanup', 'AudioService');

      // RELEASE CONNECTION: Track connection closure
      if (_currentConnectionId != null) {
        ConnectionMonitor.releaseConnection(_currentConnectionId!);
        _currentConnectionId = null;
      }

      // Stop playback
      await _audioPlayer.stop();

      // Clear audio source to force connection closure
      // Note: Just stopping is sufficient to close the connection

      // Reset current stream URL
      _currentStreamUrl = null;

      // Log active connections for debugging
      ConnectionMonitor.logActiveConnections();

      Logger.info('🔧 AudioService: Full cleanup completed', 'AudioService');
    } catch (e) {
      Logger.error('❌ AudioService: Error during cleanup: $e', 'AudioService');
    }
  }

  Future<void> pause() async {
    try {
      await _audioPlayer.pause();
    } catch (e) {
      _handleError('Failed to pause: $e');
    }
  }

  Future<void> resume() async {
    try {
      await _audioPlayer.play();
    } catch (e) {
      _handleError('Failed to resume: $e');
      // Note: Automatic reconnection is handled by RadioController
    }
  }

  Future<void> stop() async {
    try {
      Logger.info(
          '🛑 AudioService: Stopping playback and cleaning up connections',
          'AudioService');

      // Perform full cleanup to ensure connection is closed
      await _performFullCleanup();

      _stateController.add(AudioState.idle);
      Logger.info(
          '🛑 AudioService: Stop completed successfully', 'AudioService');
    } catch (e) {
      Logger.error('❌ AudioService: Failed to stop: $e', 'AudioService');
      _handleError('Failed to stop: $e');
    }
  }

  Future<void> setVolume(double volume) async {
    try {
      _currentVolume = volume.clamp(0.0, 1.0);
      await _audioPlayer.setVolume(_currentVolume);
    } catch (e) {
      _handleError('Failed to set volume: $e');
    }
  }

  double get volume => _currentVolume;

  void _handleStreamEnd() {
    // Stream ended - RadioController will handle reconnection if needed
    _stateController.add(AudioState.idle);
  }

  void _handleError(String error) {
    // Shorten error message for user
    String shortError = "Failed to play stream";
    if (error.toLowerCase().contains('network') ||
        error.toLowerCase().contains('connection')) {
      shortError = "Network error";
    } else if (error.toLowerCase().contains('format') ||
        error.toLowerCase().contains('codec')) {
      shortError = "Format error";
    } else if (error.toLowerCase().contains('timeout')) {
      shortError = "Connection timeout";
    }

    _errorController.add(shortError);
    _stateController.add(AudioState.error);
  }

  // Reconnection logic removed - handled by RadioController

  Future<void> dispose() async {
    await _playerStateSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    await _audioPlayer.dispose();
    await _stateController.close();
    await _errorController.close();
    await _bufferController.close();
    await _connectionQualityController.close();
  }
}
