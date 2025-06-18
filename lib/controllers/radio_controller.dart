import 'dart:async';
import '../models/stream_config.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/audio_service.dart';

class RadioController {
  static RadioController? _instance;

  late ApiService _apiService;
  late StorageService _storageService;
  late AudioService _audioService;

  Timer? _configCheckTimer;
  StreamConfig? _currentConfig;
  String? _currentApiKey;
  bool _isInitialized = false;

  final StreamController<String?> _apiKeyController =
      StreamController<String?>.broadcast();
  final StreamController<bool> _connectionStatusController =
      StreamController<bool>.broadcast();
  final StreamController<String> _statusMessageController =
      StreamController<String>.broadcast();

  RadioController._();

  static Future<RadioController> getInstance() async {
    _instance ??= RadioController._();
    if (!_instance!._isInitialized) {
      await _instance!._initialize();
    }
    return _instance!;
  }

  Stream<String?> get apiKeyStream => _apiKeyController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  Stream<String> get statusMessageStream => _statusMessageController.stream;
  Stream<AudioState> get audioStateStream => _audioService.stateStream;
  Stream<String> get audioErrorStream => _audioService.errorStream;
  Stream<String?> get titleStream => _audioService.titleStream;

  String? get currentApiKey => _currentApiKey;
  bool get isConnected => _currentApiKey != null && _currentConfig != null;
  AudioState get audioState => _audioService.currentState;

  Future<void> _initialize() async {
    _apiService = ApiService();
    _storageService = await StorageService.getInstance();
    _audioService = await AudioService.getInstance();

    _currentApiKey = _storageService.getApiKey();
    _apiKeyController.add(_currentApiKey);

    _audioService.errorStream.listen((error) {
      _statusMessageController.add('Audio error: $error');
    });

    _isInitialized = true;
  }

  Future<bool> connectWithApiKey(String apiKey) async {
    try {
      _statusMessageController.add('Connecting...');

      final config = await _apiService.getStreamConfig(apiKey);
      if (config != null) {
        _currentApiKey = apiKey;
        _currentConfig = config;

        await _storageService.saveApiKey(apiKey);
        await _storageService.saveLastStreamUrl(config.streamUrl);
        await _storageService.saveLastVolume(config.volume);

        _apiKeyController.add(_currentApiKey);
        _connectionStatusController.add(true);
        _statusMessageController.add('Connected successfully');

        await _audioService.playStream(config);
        _startConfigPolling();

        return true;
      } else {
        throw Exception('Invalid configuration received');
      }
    } catch (e) {
      _connectionStatusController.add(false);
      _statusMessageController.add('Connection failed: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    _configCheckTimer?.cancel();
    await _audioService.stop();

    _currentApiKey = null;
    _currentConfig = null;

    await _storageService.clearApiKey();

    _apiKeyController.add(null);
    _connectionStatusController.add(false);
    _statusMessageController.add('Disconnected');
  }

  Future<void> playPause() async {
    if (_audioService.currentState == AudioState.playing) {
      await _audioService.pause();
    } else if (_audioService.currentState == AudioState.paused ||
        _audioService.currentState == AudioState.idle) {
      if (_currentConfig != null) {
        await _audioService.playStream(_currentConfig!);
      } else {
        await _refreshConfig();
      }
    }
  }

  Future<void> setVolume(double volume) async {
    await _audioService.setVolume(volume);
    if (_currentConfig != null) {
      await _storageService.saveLastVolume(volume);
    }
  }

  double get volume => _audioService.volume;

  void _startConfigPolling() {
    _configCheckTimer?.cancel();
    _configCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _refreshConfig();
    });
  }

  Future<void> _refreshConfig() async {
    if (_currentApiKey == null) return;

    try {
      final newConfig = await _apiService.getStreamConfig(_currentApiKey!);
      if (newConfig != null && newConfig != _currentConfig) {
        _currentConfig = newConfig;

        await _storageService.saveLastStreamUrl(newConfig.streamUrl);
        await _storageService.saveLastVolume(newConfig.volume);

        if (_audioService.currentState == AudioState.playing ||
            _audioService.currentState == AudioState.buffering) {
          await _audioService.playStream(newConfig);
        }

        _statusMessageController.add('Stream updated');
      }
    } catch (e) {
      _statusMessageController.add('Failed to refresh config: $e');
    }
  }

  Future<void> handleAutoStart() async {
    if (_currentApiKey != null && _currentApiKey!.isNotEmpty) {
      // Запускаем подключение в фоне, не ждем завершения
      connectWithApiKey(_currentApiKey!).catchError((error) {
        _statusMessageController.add('Auto-connect failed: $error');
      });
      // Сразу устанавливаем статус что автозапуск инициирован
      _statusMessageController.add('Auto-connecting...');
    } else {
      _statusMessageController.add('Ready');
      _connectionStatusController.add(false);
    }
  }

  Future<void> dispose() async {
    _configCheckTimer?.cancel();
    await _audioService.dispose();
    await _apiKeyController.close();
    await _connectionStatusController.close();
    await _statusMessageController.close();
  }
}
