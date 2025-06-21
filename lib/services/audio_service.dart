import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/stream_config.dart';
import '../utils/logger.dart';
import '../utils/audio_config.dart';

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

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast();

  AudioService._();

  static Future<AudioService> getInstance() async {
    _instance ??= AudioService._();
    await _instance!._initialize();
    return _instance!;
  }

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<Duration> get bufferStream => _bufferController.stream;

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

    // Configure audio player with enhanced buffering for radio streaming
    // TEMPORARILY USING SIMPLE CONFIG to diagnose buffer issues
    final config = AudioConfig.getSimpleStreamingConfiguration();
    Logger.info(
        '🔧 AudioService: Using SIMPLE buffer config for better compatibility',
        'AudioService');

    _audioPlayer = AudioPlayer(
      userAgent: AudioConfig.userAgent,
      useProxyForRequestHeaders: true,
      audioLoadConfiguration: config,
    );

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      final currentAudioState = currentState;
      Logger.debug(
          '🎵 AudioService: Player state changed to ${state.processingState}, playing: ${state.playing}',
          'AudioService');
      Logger.debug('🎵 AudioService: Current audio state: $currentAudioState',
          'AudioService');

      _stateController.add(currentAudioState);

      if (state.processingState == ProcessingState.completed) {
        Logger.debug('🎵 AudioService: Stream completed, handling stream end',
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

    // Enhanced buffering monitoring with detailed diagnostics
    _audioPlayer.bufferedPositionStream.listen((bufferedPosition) {
      final currentPosition = _audioPlayer.position;
      final bufferAhead = bufferedPosition - currentPosition;

      // Always send buffer info to stream (even if 0)
      _bufferController.add(bufferAhead);

      // Detailed logging for buffer analysis
      Logger.debug(
          '🔍 AudioService DETAILED: bufferedPos=${bufferedPosition.inSeconds}s, currentPos=${currentPosition.inSeconds}s, bufferAhead=${bufferAhead.inSeconds}s, playing=${_audioPlayer.playing}, state=${_audioPlayer.processingState}',
          'AudioService');

      if (bufferAhead.inSeconds >= 0) {
        final bufferStatus =
            AudioConfig.getBufferStatusDescription(bufferAhead);
        final isHealthy = AudioConfig.isBufferHealthy(bufferAhead);

        Logger.debug(
            '🎵 AudioService: $bufferStatus (pos: ${currentPosition.inSeconds}s, buffered: ${bufferedPosition.inSeconds}s) ${isHealthy ? '✅' : '⚠️'}',
            'AudioService');

        // Special analysis for stuck buffer
        if (bufferAhead.inSeconds <= 2 && _audioPlayer.playing) {
          Logger.warning(
              '⚠️ AudioService: Buffer stuck at ${bufferAhead.inSeconds}s - This might indicate AndroidLoadControl settings are not working properly on this device',
              'AudioService');
          Logger.warning(
              '📊 AudioService: Raw data - bufferedPos: ${bufferedPosition.inSeconds}s, currentPos: ${currentPosition.inSeconds}s, playing: ${_audioPlayer.playing}, state: ${_audioPlayer.processingState}',
              'AudioService');
        }

        // Warn on low buffer during playback
        if (!isHealthy && _audioPlayer.playing && bufferAhead.inSeconds > 0) {
          Logger.warning(
              '🎵 AudioService: Low buffer detected during playback - potential stuttering risk',
              'AudioService');
        }
      } else {
        Logger.warning(
            '❌ AudioService: Negative buffer - bufferedPos: ${bufferedPosition.inSeconds}s, currentPos: ${currentPosition.inSeconds}s',
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
      } else {
        Logger.info(
            '🌐 AudioService: Network connection restored', 'AudioService');
      }
    });
  }

  Future<void> playStream(StreamConfig config) async {
    try {
      Logger.debug(
          '🎵 AudioService: Starting playStream with URL: ${config.streamUrl}',
          'AudioService');
      Logger.debug(
          '🎵 AudioService: Stream title: ${config.title}', 'AudioService');
      Logger.debug(
          '🎵 AudioService: Stream volume: ${config.volume}', 'AudioService');

      _stateController.add(AudioState.loading);

      if (_currentStreamUrl != config.streamUrl) {
        await _audioPlayer.stop();

        Logger.debug(
            '🎵 AudioService: Creating audio source for URL: ${config.streamUrl}',
            'AudioService');
        final uri = Uri.parse(config.streamUrl);
        Logger.debug('🎵 AudioService: Parsed URI: $uri', 'AudioService');
        Logger.debug(
            '🎵 AudioService: URI scheme: ${uri.scheme}', 'AudioService');
        Logger.debug('🎵 AudioService: URI host: ${uri.host}', 'AudioService');
        Logger.debug('🎵 AudioService: URI path: ${uri.path}', 'AudioService');

        final audioSource = ProgressiveAudioSource(
          uri,
          headers: AudioConfig.getStreamingHeaders(),
        );

        Logger.debug(
            '🎵 AudioService: Setting audio source with buffering config...',
            'AudioService');

        // Set audio source with preloading for better buffering
        await _audioPlayer.setAudioSource(
          audioSource,
          initialPosition: Duration.zero,
          preload: true,
        );

        _currentStreamUrl = config.streamUrl;
        Logger.debug(
            '🎵 AudioService: Audio source set successfully with enhanced buffering',
            'AudioService');
      }

      await setVolume(config.volume);
      Logger.debug('🎵 AudioService: Starting playback...', 'AudioService');
      await _audioPlayer.play();

      Logger.debug(
          '🎵 AudioService: Playback started successfully', 'AudioService');
    } catch (e) {
      Logger.error('❌ AudioService: Error in playStream: $e', 'AudioService');
      Logger.error(
          '❌ AudioService: Error type: ${e.runtimeType}', 'AudioService');
      _handleError('Failed to play stream: $e');
      // Note: Automatic reconnection is handled by RadioController
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
      await _audioPlayer.stop();
      _currentStreamUrl = null;
      _stateController.add(AudioState.idle);
    } catch (e) {
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
  }
}
