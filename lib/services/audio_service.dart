import 'dart:async';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/stream_config.dart';

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

  AudioService._();

  static Future<AudioService> getInstance() async {
    _instance ??= AudioService._();
    await _instance!._initialize();
    return _instance!;
  }

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String> get errorStream => _errorController.stream;

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
    _audioPlayer = AudioPlayer(
      // Use proxy for better header support and improved buffering
      useProxyForRequestHeaders: true,
    );

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      final currentAudioState = currentState;
      print(
          '🎵 AudioService: Player state changed to ${state.processingState}, playing: ${state.playing}');
      print('🎵 AudioService: Current audio state: $currentAudioState');

      _stateController.add(currentAudioState);

      if (state.processingState == ProcessingState.completed) {
        print('🎵 AudioService: Stream completed, handling stream end');
        _handleStreamEnd();
      }
    });

    // Listen to error stream for enhanced error handling in just_audio 0.10.x
    _audioPlayer.errorStream.listen((error) {
      print('❌ AudioService: Player error: $error');
      _handleError('Player error: ${error.message}');
    });

    _audioPlayer.playbackEventStream.listen((event) {
      if (event.processingState == ProcessingState.ready) {
        print('🎵 AudioService: Stream ready');
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
        print('🌐 AudioService: Network connection lost');
      } else {
        print('🌐 AudioService: Network connection restored');
      }
    });
  }

  Future<void> playStream(StreamConfig config) async {
    try {
      print(
          '🎵 AudioService: Starting playStream with URL: ${config.streamUrl}');
      print('🎵 AudioService: Stream title: ${config.title}');
      print('🎵 AudioService: Stream volume: ${config.volume}');

      _stateController.add(AudioState.loading);

      if (_currentStreamUrl != config.streamUrl) {
        await _audioPlayer.stop();

        print(
            '🎵 AudioService: Creating audio source for URL: ${config.streamUrl}');
        final uri = Uri.parse(config.streamUrl);
        print('🎵 AudioService: Parsed URI: $uri');
        print('🎵 AudioService: URI scheme: ${uri.scheme}');
        print('🎵 AudioService: URI host: ${uri.host}');
        print('🎵 AudioService: URI path: ${uri.path}');

        final audioSource = ProgressiveAudioSource(
          uri,
          headers: {
            'User-Agent': 'TunioRadioPlayer/1.0 (Mobile)',
            'Icy-MetaData': '1',
            'Connection': 'keep-alive',
            'Cache-Control': 'no-cache',
            'Accept': 'audio/*',
            'Range': 'bytes=0-',
          },
        );

        print('🎵 AudioService: Setting audio source...');
        await _audioPlayer.setAudioSource(audioSource);
        _currentStreamUrl = config.streamUrl;
        print('🎵 AudioService: Audio source set successfully');
      }

      await setVolume(config.volume);
      print('🎵 AudioService: Starting playback...');
      await _audioPlayer.play();

      print('🎵 AudioService: Playback started successfully');
    } catch (e) {
      print('❌ AudioService: Error in playStream: $e');
      print('❌ AudioService: Error type: ${e.runtimeType}');
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
    // Сокращаем сообщение об ошибке для пользователя
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
  }
}
