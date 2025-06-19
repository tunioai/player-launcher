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
  Timer? _streamHealthTimer;
  StreamConfig? _currentConfig;
  String? _currentToken;
  bool _isInitialized = false;
  bool _autoConnectEnabled = false;
  bool _isRetrying = false;
  bool _isStreamHealthy = false;
  int _retryAttempts = 0;
  int _consecutiveFailures = 0;
  DateTime? _lastSuccessfulConnection;
  DateTime? _lastStreamStart;

  final StreamController<String?> _tokenController =
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

  Stream<String?> get tokenStream => _tokenController.stream;
  Stream<String?> get apiKeyStream => _tokenController.stream;
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  Stream<String> get statusMessageStream => _statusMessageController.stream;
  Stream<AudioState> get audioStateStream => _audioService.stateStream;
  Stream<String> get audioErrorStream => _audioService.errorStream;
  Stream<String?> get titleStream => _audioService.titleStream;

  String? get currentToken => _currentToken;
  String? get currentApiKey => _currentToken;
  bool get isConnected => _currentToken != null && _currentConfig != null;
  AudioState get audioState => _audioService.currentState;

  Future<void> _initialize() async {
    _apiService = ApiService();
    _storageService = await StorageService.getInstance();
    _audioService = await AudioService.getInstance();
    _networkService = NetworkService.getInstance();

    _currentToken = _storageService.getToken();
    Logger.info(
        'RadioController: Loaded token from storage: ${_currentToken != null ? '[PRESENT]' : '[MISSING]'}');
    _tokenController.add(_currentToken);

    // Try to restore last configuration if token exists
    if (_currentToken != null && _currentToken!.isNotEmpty) {
      final lastUrl = _storageService.getLastStreamUrl();
      final lastVolume = _storageService.getLastVolume();
      if (lastUrl != null && lastUrl.isNotEmpty) {
        _currentConfig = StreamConfig(
          streamUrl: lastUrl,
          title: 'Radio Stream',
          volume: lastVolume,
        );
        Logger.info(
            'RadioController: Restored last configuration - URL: ${lastUrl.substring(0, 20)}..., Volume: $lastVolume');
      }
    }

    _setupAudioErrorHandling();
    _setupAudioStateHandling();
    _setupNetworkHandling();
    _startStreamHealthMonitoring();

    _networkService.startMonitoring();
    _isInitialized = true;
  }

  void _setupAudioErrorHandling() {
    _audioService.errorStream.listen((error) {
      Logger.error('RadioController: Audio error - $error');
      _statusMessageController.add('Audio error: $error');
      _isStreamHealthy = false;
      _consecutiveFailures++;

      if (_currentToken != null && _currentConfig != null && !_isRetrying) {
        _triggerReconnection('Audio error occurred');
      }
    });
  }

  void _setupAudioStateHandling() {
    _audioService.stateStream.listen((state) {
      Logger.info('RadioController: Audio state changed to $state');

      switch (state) {
        case AudioState.playing:
          _statusMessageController.add('Playing');
          _isRetrying = false;
          _isStreamHealthy = true;
          _consecutiveFailures = 0;
          _lastStreamStart = DateTime.now();
          Logger.info('RadioController: Stream playing successfully');
          break;

        case AudioState.loading:
        case AudioState.buffering:
          _handleLoadingBufferingTimeout();
          break;

        case AudioState.error:
          _isStreamHealthy = false;
          if (_currentToken != null && _currentConfig != null && !_isRetrying) {
            _triggerReconnection('Stream error');
          }
          break;

        case AudioState.idle:
          _isStreamHealthy = false;
          break;

        default:
          break;
      }
    });
  }

  void _setupNetworkHandling() {
    _networkService.connectivityStream.listen((isConnected) {
      if (isConnected && _autoConnectEnabled && _currentToken != null) {
        Logger.info('RadioController: Network restored, attempting reconnect');
        _attemptConnection();
      } else if (!isConnected) {
        Logger.warning('RadioController: Network lost');
        _isStreamHealthy = false;
        _statusMessageController.add('Network connection lost');
      }
    });
  }

  void _handleLoadingBufferingTimeout() {
    Timer(const Duration(seconds: 60), () {
      if ((_audioService.currentState == AudioState.loading ||
              _audioService.currentState == AudioState.buffering) &&
          _currentConfig != null &&
          !_isRetrying) {
        Logger.warning('RadioController: Stream timeout after 60 seconds');
        _statusMessageController.add('Stream timeout, reconnecting...');
        _triggerReconnection('Stream loading/buffering timeout');
      }
    });
  }

  void _startStreamHealthMonitoring() {
    _streamHealthTimer?.cancel();
    _streamHealthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkStreamHealth();
    });
  }

  void _checkStreamHealth() {
    if (_currentToken == null || _currentConfig == null) return;

    final now = DateTime.now();

    // Check if stream has been in an unhealthy state for too long
    if (!_isStreamHealthy &&
        _lastStreamStart != null &&
        now.difference(_lastStreamStart!).inMinutes > 5) {
      Logger.warning('RadioController: Stream unhealthy for over 5 minutes');
      if (!_isRetrying) {
        _triggerReconnection('Stream health check failed');
      }
    }

    // Check if we're stuck in loading/buffering for too long
    final audioState = _audioService.currentState;
    if ((audioState == AudioState.loading ||
            audioState == AudioState.buffering) &&
        _lastStreamStart != null &&
        now.difference(_lastStreamStart!).inMinutes > 2) {
      Logger.warning('RadioController: Stream stuck in loading/buffering');
      if (!_isRetrying) {
        _triggerReconnection('Stream stuck in loading state');
      }
    }
  }

  void _triggerReconnection(String reason) {
    if (_isRetrying) return;

    Logger.info('RadioController: Triggering reconnection - $reason');
    _autoConnectEnabled = true;
    _startAutoConnect();
  }

  String _statusMessage = 'Ready';

  Future<bool> connectWithToken(String token) async {
    _autoConnectEnabled = false;
    _retryTimer?.cancel();

    try {
      _statusMessageController.add('Connecting...');
      Logger.info('RadioController: Attempting connection with token');

      final config = await _apiService.getStreamConfigWithToken(token);
      if (config != null) {
        _currentToken = token;
        _currentConfig = config;

        await _storageService.saveToken(token);
        await _storageService.saveLastStreamUrl(config.streamUrl);
        await _storageService.saveLastVolume(config.volume);

        _tokenController.add(_currentToken);
        _connectionStatusController.add(true);
        _statusMessageController.add('Connected successfully');
        _lastSuccessfulConnection = DateTime.now();

        try {
          await _audioService.playStream(config);
          _lastStreamStart = DateTime.now();
        } catch (e) {
          Logger.error('RadioController: Failed to start audio stream: $e');
          _triggerReconnection(
              'Failed to start audio after successful API connection');
          return true; // API connection was successful, let auto-reconnect handle audio
        }

        _startConfigPolling();
        return true;
      } else {
        throw Exception('Invalid configuration received from API');
      }
    } catch (e) {
      Logger.error('RadioController: Connection failed: $e');
      _connectionStatusController.add(false);
      _statusMessageController.add('Connection failed: $e');
      _consecutiveFailures++;
      return false;
    }
  }

  Future<bool> connectWithApiKey(String apiKey) async {
    return await connectWithToken(apiKey);
  }

  Future<void> disconnect() async {
    Logger.info('RadioController: Disconnecting');
    _autoConnectEnabled = false;
    _configCheckTimer?.cancel();
    _retryTimer?.cancel();
    _streamHealthTimer?.cancel();

    await _audioService.stop();

    _currentToken = null;
    _currentConfig = null;
    _isStreamHealthy = false;
    _consecutiveFailures = 0;

    await _storageService.clearToken();

    _tokenController.add(null);
    _connectionStatusController.add(false);
    _statusMessageController.add('Disconnected');
  }

  Future<void> playPause() async {
    if (_audioService.currentState == AudioState.playing) {
      await _audioService.pause();
    } else if (_audioService.currentState == AudioState.paused ||
        _audioService.currentState == AudioState.idle) {
      if (_currentConfig != null) {
        _lastStreamStart = DateTime.now();
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

  Future<void> reconnect() async {
    if (_currentToken != null && _currentToken!.isNotEmpty) {
      Logger.info('RadioController: Manual reconnect triggered');
      _statusMessageController.add('Reconnecting...');

      if (_currentConfig != null) {
        try {
          await _audioService.stop();
          _lastStreamStart = DateTime.now();
          await _audioService.playStream(_currentConfig!);
          return;
        } catch (e) {
          Logger.error('RadioController: Direct stream restart failed: $e');
        }
      }

      final success = await connectWithToken(_currentToken!);
      if (!success) {
        _triggerReconnection('Manual reconnect failed');
      }
    }
  }

  void _startConfigPolling() {
    _configCheckTimer?.cancel();
    _configCheckTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _refreshConfig();
    });
  }

  Future<void> _refreshConfig() async {
    if (_currentToken == null) return;

    try {
      final newConfig =
          await _apiService.getStreamConfigWithToken(_currentToken!);
      if (newConfig != null && newConfig != _currentConfig) {
        Logger.info('RadioController: Config updated');
        _currentConfig = newConfig;

        await _storageService.saveLastStreamUrl(newConfig.streamUrl);
        await _storageService.saveLastVolume(newConfig.volume);

        if (_audioService.currentState == AudioState.playing ||
            _audioService.currentState == AudioState.buffering) {
          _lastStreamStart = DateTime.now();
          await _audioService.playStream(newConfig);
        }

        _statusMessageController.add('Stream updated');
      }
    } catch (e) {
      Logger.error('RadioController: Failed to refresh config: $e');
      _consecutiveFailures++;
      if (_currentToken != null && _currentToken!.isNotEmpty) {
        _triggerReconnection('Config refresh failed');
      }
    }
  }

  Future<void> handleAutoStart() async {
    if (_currentToken != null && _currentToken!.isNotEmpty) {
      Logger.info(
          'RadioController: Auto-start triggered with token: ${_currentToken!.substring(0, 2)}****');
      _autoConnectEnabled = true;
      _statusMessageController.add('Auto-starting...');
      _startAutoConnect();
    } else {
      Logger.info('RadioController: Auto-start called but no token found');
      _statusMessageController.add('Ready');
      _connectionStatusController.add(false);
    }
  }

  Future<void> handleNormalStart() async {
    // For normal app start, restore token and auto-connect if available
    if (_currentToken != null && _currentToken!.isNotEmpty) {
      Logger.info(
          'RadioController: Normal app start with saved token - auto-connecting');

      // If we already have a restored configuration, try to start playback immediately
      if (_currentConfig != null) {
        Logger.info(
            'RadioController: Found restored config, starting playback immediately');
        _connectionStatusController.add(true);
        _statusMessageController.add('Restoring playback...');

        try {
          _lastStreamStart = DateTime.now();
          await _audioService.playStream(_currentConfig!);
          _statusMessageController.add('Playing');
          _startConfigPolling();
          Logger.info(
              'RadioController: Successfully restored playback from saved config');
        } catch (e) {
          Logger.error(
              'RadioController: Failed to start playback from saved config: $e');
          // Fall back to full reconnection if playback fails
          _autoConnectEnabled = true;
          _statusMessageController.add('Restoring connection...');
          _startAutoConnect();
        }
      } else {
        // No saved config, do full reconnection
        _autoConnectEnabled = true;
        _statusMessageController.add('Restoring connection...');
        _startAutoConnect();
      }
    } else {
      Logger.info('RadioController: Normal app start - no saved token found');
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
        _currentToken == null ||
        _currentToken!.isEmpty) {
      return;
    }

    _isRetrying = true;
    _retryAttempts++;

    Logger.info('RadioController: Connection attempt #$_retryAttempts');

    final hasInternet = await _networkService.checkInternetConnection();
    if (!hasInternet) {
      _statusMessageController.add(
          'No internet connection (attempt $_retryAttempts) - retrying...');
      _scheduleRetry();
      return;
    }

    _statusMessageController.add('Connecting (attempt $_retryAttempts)...');

    try {
      final config = await _apiService.getStreamConfigWithToken(_currentToken!);
      if (config != null) {
        _currentConfig = config;
        await _storageService.saveLastStreamUrl(config.streamUrl);
        await _storageService.saveLastVolume(config.volume);

        _connectionStatusController.add(true);
        _statusMessageController.add('Connected successfully');
        _lastSuccessfulConnection = DateTime.now();
        _consecutiveFailures = 0;

        // Always start audio playback after successful API connection during auto-connect
        try {
          _lastStreamStart = DateTime.now();
          await _audioService.playStream(config);
          _statusMessageController.add('Playing');
          _autoConnectEnabled = false;
          _retryTimer?.cancel();
          _isRetrying = false;
          Logger.info(
              'RadioController: Audio playback started successfully during auto-connect');
        } catch (e) {
          Logger.error(
              'RadioController: Audio start failed after API success: $e');
          _statusMessageController.add('Audio start failed - retrying...');
          _scheduleRetry();
          return;
        }

        _startConfigPolling();
        Logger.info(
            'RadioController: Auto-connect successful after $_retryAttempts attempts');
        return;
      } else {
        throw Exception('Invalid configuration received from API');
      }
    } catch (e) {
      Logger.error(
          'RadioController: Connection attempt $_retryAttempts failed: $e');
      _consecutiveFailures++;
      _statusMessageController
          .add('Connection failed (attempt $_retryAttempts): $e - retrying...');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!_autoConnectEnabled) {
      _isRetrying = false;
      return;
    }

    _retryTimer?.cancel();

    // Adaptive delay based on failure count and attempt number
    int delay;
    if (_retryAttempts <= 5) {
      delay = _retryAttempts * 3; // 3, 6, 9, 12, 15 seconds
    } else if (_retryAttempts <= 10) {
      delay = 30; // 30 seconds for attempts 6-10
    } else if (_retryAttempts <= 20) {
      delay = 60; // 1 minute for attempts 11-20
    } else {
      delay = 300; // 5 minutes for attempts 21+
    }

    // Increase delay if we have many consecutive failures
    if (_consecutiveFailures > 10) {
      delay = delay * 2; // Double the delay
    }

    Logger.info(
        'RadioController: Scheduling retry #${_retryAttempts + 1} in ${delay}s (consecutive failures: $_consecutiveFailures)');

    _retryTimer = Timer(Duration(seconds: delay), () {
      if (_autoConnectEnabled) {
        _attemptConnection();
      } else {
        _isRetrying = false;
      }
    });
  }

  Future<void> dispose() async {
    Logger.info('RadioController: Disposing');
    _autoConnectEnabled = false;
    _configCheckTimer?.cancel();
    _retryTimer?.cancel();
    _streamHealthTimer?.cancel();
    _networkService.stopMonitoring();
    await _audioService.dispose();
    await _tokenController.close();
    await _connectionStatusController.close();
    await _statusMessageController.close();
  }
}
