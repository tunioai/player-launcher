import 'dart:async';
import '../models/stream_config.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/audio_service.dart';
import '../services/network_service.dart';
import '../utils/logger.dart';

class RadioController {
  static RadioController? _instance;

  late ApiService _apiService;
  late StorageService _storageService;
  late AudioService _audioService;
  late NetworkService _networkService;

  Timer? _configCheckTimer;
  Timer? _retryTimer;
  StreamConfig? _currentConfig;
  String? _currentApiKey;
  bool _isInitialized = false;
  bool _autoConnectEnabled = false;
  int _retryAttempts = 0;
  int _maxRetryAttempts = -1; // -1 = бесконечные попытки

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
    _networkService = NetworkService.getInstance();

    _currentApiKey = _storageService.getApiKey();
    _apiKeyController.add(_currentApiKey);

    _audioService.errorStream.listen((error) {
      _statusMessageController.add('Audio error: $error');
    });

    // Слушаем изменения подключения к интернету
    _networkService.connectivityStream.listen((isConnected) {
      if (isConnected && _autoConnectEnabled && _currentApiKey != null) {
        Logger.info(
            'RadioController: Internet restored, attempting reconnect...');
        _attemptConnection();
      }
    });

    _networkService.startMonitoring();
    _isInitialized = true;
  }

  Future<bool> connectWithApiKey(String apiKey) async {
    // Останавливаем автоподключение при ручном подключении
    _autoConnectEnabled = false;
    _retryTimer?.cancel();

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
    _autoConnectEnabled = false;
    _configCheckTimer?.cancel();
    _retryTimer?.cancel();
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
      _autoConnectEnabled = true;
      _statusMessageController.add('Waiting for internet connection...');
      _startAutoConnect();
    } else {
      _statusMessageController.add('Ready');
      _connectionStatusController.add(false);
    }
  }

  void _startAutoConnect() {
    _retryAttempts = 0;
    _attemptConnection();
  }

  Future<void> _attemptConnection() async {
    if (!_autoConnectEnabled ||
        _currentApiKey == null ||
        _currentApiKey!.isEmpty) {
      return;
    }

    _retryAttempts++;

    // Проверяем интернет
    final hasInternet = await _networkService.checkInternetConnection();
    if (!hasInternet) {
      _statusMessageController.add(
          'No internet connection (attempt $_retryAttempts) - retrying...');
      _scheduleRetry();
      return;
    }

    _statusMessageController.add('Connecting (attempt $_retryAttempts)...');

    try {
      final config = await _apiService.getStreamConfig(_currentApiKey!);
      if (config != null) {
        _currentConfig = config;
        await _storageService.saveLastStreamUrl(config.streamUrl);
        await _storageService.saveLastVolume(config.volume);

        _connectionStatusController.add(true);
        _statusMessageController.add('Connected successfully');
        _autoConnectEnabled = false;
        _retryTimer?.cancel();

        await _audioService.playStream(config);
        _startConfigPolling();

        Logger.info(
            'RadioController: Auto-connect successful after $_retryAttempts attempts');
        return;
      } else {
        throw Exception('Invalid configuration received');
      }
    } catch (e) {
      Logger.error(
          'RadioController: Connection attempt $_retryAttempts failed: $e');
      _statusMessageController
          .add('Connection failed (attempt $_retryAttempts): $e - retrying...');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!_autoConnectEnabled) return;

    _retryTimer?.cancel();

    // Увеличивающаяся задержка: 5s, 10s, 15s, 30s, 60s, затем каждые 60s
    int delay;
    if (_retryAttempts <= 3) {
      delay = _retryAttempts * 5;
    } else if (_retryAttempts <= 6) {
      delay = 30;
    } else {
      delay = 60;
    }

    Logger.info(
        'RadioController: Scheduling retry #${_retryAttempts + 1} in ${delay}s');

    _retryTimer = Timer(Duration(seconds: delay), () {
      if (_autoConnectEnabled) {
        _attemptConnection();
      }
    });
  }

  Future<void> dispose() async {
    _autoConnectEnabled = false;
    _configCheckTimer?.cancel();
    _retryTimer?.cancel();
    _networkService.stopMonitoring();
    await _audioService.dispose();
    await _apiKeyController.close();
    await _connectionStatusController.close();
    await _statusMessageController.close();
  }
}
