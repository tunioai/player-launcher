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
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;
  Stream<String> get statusMessageStream => _statusMessageController.stream;
  Stream<AudioState> get audioStateStream => _audioService.stateStream;
  Stream<String> get audioErrorStream => _audioService.errorStream;
  Stream<String?> get titleStream => _audioService.titleStream;

  String? get currentToken => _currentToken;
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

        // Set initial connection status based on restored state
        _connectionStatusController.add(true);
      } else {
        _connectionStatusController.add(false);
      }
    } else {
      _connectionStatusController.add(false);
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
    _retryAttempts = 0;
    _attemptConnection();
  }

  String _statusMessage = 'Ready';

  Future<bool> connectWithToken(String token) async {
    return await connect(token);
  }

  /// Unified connection method that handles both manual and automatic connections
  /// Auto-reconnect is always enabled for autonomous operation
  Future<bool> connect(String token, {bool isRetry = false}) async {
    if (!isRetry) {
      // Stop any existing retry logic when starting a new connection
      _autoConnectEnabled = false;
      _retryTimer?.cancel();
    }

    try {
      _statusMessageController.add('Connecting...');
      Logger.info(
          'RadioController: Attempting connection with token (autoReconnect: always enabled)');

      final config = await _apiService.getStreamConfigWithToken(token);
      if (config != null) {
        _currentToken = token;
        _currentConfig = config;

        await _storageService.saveToken(token);
        await _storageService.saveLastStreamUrl(config.streamUrl);
        await _storageService.saveLastVolume(config.volume);

        _tokenController.add(_currentToken);
        Logger.info('RadioController: Broadcasting connection status: true');
        _connectionStatusController.add(true);
        Logger.info(
            'RadioController: Broadcasting status message: Connected successfully');
        _statusMessageController.add('Connected successfully');
        _lastSuccessfulConnection = DateTime.now();

        try {
          await _audioService.playStream(config);
          _lastStreamStart = DateTime.now();
          _statusMessageController.add('Playing');
        } catch (e) {
          Logger.error('RadioController: Failed to start audio stream: $e');
          _triggerReconnection(
              'Failed to start audio after successful API connection');
          return true; // API connection was successful
        }

        // Enable auto-reconnection and start config polling after successful connection
        _autoConnectEnabled = true;
        _startConfigPolling();

        // Reset retry state on success
        _retryAttempts = 0;
        _consecutiveFailures = 0;
        _isRetrying = false;

        return true;
      } else {
        throw Exception('Invalid configuration received from API');
      }
    } catch (e) {
      Logger.error('RadioController: Connection failed: $e');
      _connectionStatusController.add(false);
      _statusMessageController.add('Connection failed: $e');
      _consecutiveFailures++;

      if (!isRetry) {
        // Start auto-reconnect logic for failed connections
        _autoConnectEnabled = true;
        _triggerReconnection('Initial connection failed');
      }

      return false;
    }
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
    await _handleAppStart(isAutoStart: true);
  }

  Future<void> handleNormalStart() async {
    await _handleAppStart(isAutoStart: false);
  }

  /// Unified app start handler for both auto-start and normal start
  Future<void> _handleAppStart({required bool isAutoStart}) async {
    final startType = isAutoStart ? 'Auto-start' : 'Normal app start';

    if (_currentToken != null && _currentToken!.isNotEmpty) {
      Logger.info(
          'RadioController: $startType with saved token: ${_currentToken!.substring(0, 2)}****');

      // Try to restore from saved config first (faster startup)
      if (_currentConfig != null) {
        Logger.info(
            'RadioController: Found restored config, attempting quick start');
        Logger.info(
            'RadioController: Broadcasting connection status: true (quick start)');
        _connectionStatusController.add(true);
        Logger.info(
            'RadioController: Broadcasting status message: Restoring playback...');
        _statusMessageController.add('Restoring playback...');

        try {
          _lastStreamStart = DateTime.now();
          await _audioService.playStream(_currentConfig!);
          Logger.info(
              'RadioController: Broadcasting status message: Playing (quick start)');
          _statusMessageController.add('Playing');
          _autoConnectEnabled =
              true; // Enable auto-reconnect for autonomous operation
          _startConfigPolling();
          Logger.info(
              'RadioController: Successfully restored playback from saved config');
          return;
        } catch (e) {
          Logger.error(
              'RadioController: Failed to start from saved config: $e');
          _connectionStatusController.add(false);
          // Fall through to full reconnection
        }
      }

      // Full reconnection
      _statusMessageController.add('Connecting...');
      final success = await connect(_currentToken!);

      if (!success) {
        Logger.warning(
            'RadioController: $startType connection failed, auto-reconnect will continue trying');
      }
    } else {
      Logger.info('RadioController: $startType - no saved token found');
      _statusMessageController.add('Ready');
      _connectionStatusController.add(false);
    }
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

    // Use the unified connect method with retry flag
    final success = await connect(_currentToken!, isRetry: true);

    if (success) {
      // Connection successful - stop retrying
      _retryTimer?.cancel();
      _isRetrying = false;
      Logger.info(
          'RadioController: Auto-connect successful after $_retryAttempts attempts');
    } else {
      // Connection failed - schedule retry
      Logger.error(
          'RadioController: Connection attempt $_retryAttempts failed');
      _statusMessageController
          .add('Connection failed (attempt $_retryAttempts) - retrying...');
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
