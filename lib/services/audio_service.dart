import 'dart:async';
import 'dart:io';
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
  Timer? _reconnectTimer;

  String? _currentStreamUrl;
  double _currentVolume = 1.0;
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;
  static const int maxReconnectAttempts = 10;
  static const Duration reconnectInterval = Duration(seconds: 5);

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();
  final StreamController<String?> _titleController =
      StreamController<String?>.broadcast();

  AudioService._();

  static Future<AudioService> getInstance() async {
    _instance ??= AudioService._();
    await _instance!._initialize();
    return _instance!;
  }

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String> get errorStream => _errorController.stream;
  Stream<String?> get titleStream => _titleController.stream;

  AudioState get currentState {
    if (_audioPlayer.processingState == ProcessingState.loading) {
      return AudioState.loading;
    } else if (_audioPlayer.processingState == ProcessingState.buffering) {
      return AudioState.buffering;
    } else if (_audioPlayer.playing) {
      return AudioState.playing;
    } else if (_audioPlayer.processingState == ProcessingState.ready) {
      return AudioState.paused;
    } else {
      return AudioState.idle;
    }
  }

  Future<void> _initialize() async {
    _audioSession = await AudioSession.instance;
    await _audioSession.configure(const AudioSessionConfiguration.music());

    _audioPlayer = AudioPlayer();

    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      _stateController.add(currentState);

      if (state.processingState == ProcessingState.completed) {
        _handleStreamEnd();
      }
    });

    _audioPlayer.playbackEventStream.listen((event) {
      if (event.processingState == ProcessingState.ready) {
        _reconnectAttempts = 0;
        _isReconnecting = false;
      }
    });

    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((result) =>
          result == ConnectivityResult.mobile ||
          result == ConnectivityResult.wifi ||
          result == ConnectivityResult.ethernet);

      if (hasConnection && _currentStreamUrl != null && !_audioPlayer.playing) {
        _scheduleReconnect();
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

        final audioSource = AudioSource.uri(
          uri,
          headers: {
            'User-Agent': 'TunioRadioPlayer/1.0',
            'Icy-MetaData': '1',
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

      _titleController.add(config.title);
      print('🎵 AudioService: Playback started successfully');
    } catch (e) {
      print('❌ AudioService: Error in playStream: $e');
      print('❌ AudioService: Error type: ${e.runtimeType}');
      _handleError('Failed to play stream: $e');
      _scheduleReconnect();
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
      _scheduleReconnect();
    }
  }

  Future<void> stop() async {
    try {
      _reconnectTimer?.cancel();
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
    if (_currentStreamUrl != null) {
      _scheduleReconnect();
    }
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

  void _scheduleReconnect() {
    if (_isReconnecting || _reconnectAttempts >= maxReconnectAttempts) {
      return;
    }

    _isReconnecting = true;
    _reconnectTimer?.cancel();

    _reconnectTimer = Timer(reconnectInterval, () async {
      if (_currentStreamUrl != null) {
        _reconnectAttempts++;
        try {
          await _audioPlayer.play();
          _isReconnecting = false;
        } catch (e) {
          if (_reconnectAttempts < maxReconnectAttempts) {
            _scheduleReconnect();
          } else {
            _handleError('Maximum reconnection attempts reached');
          }
        }
      }
    });
  }

  Future<void> dispose() async {
    _reconnectTimer?.cancel();
    await _playerStateSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _connectivitySubscription?.cancel();
    await _audioPlayer.dispose();
    await _stateController.close();
    await _errorController.close();
    await _titleController.close();
  }
}
