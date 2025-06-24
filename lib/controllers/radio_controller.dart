import 'dart:async';
import '../models/stream_config.dart';
import '../models/api_error.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/audio_service.dart';
import '../services/network_service.dart';
import '../utils/logger.dart';
import '../utils/connection_monitor.dart';

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
  DateTime? _lastStreamStart;
  Duration _currentBufferSize = Duration.zero;
  DateTime? _zeroBufferStartTime;

  // DEBOUNCING: Prevent rapid reconnection attempts
  Timer? _reconnectionDebounceTimer;
  DateTime? _lastReconnectionRequest;
  String? _pendingReconnectionReason;
  static const Duration _reconnectionDebounceDelay = Duration(seconds: 5);

  final StreamController<String?> _tokenController =
      StreamController<String?>.broadcast();
  final StreamController<bool> _connectionStatusController =
      StreamController<bool>.broadcast();
  final StreamController<String> _statusMessageController =
      StreamController<String>.broadcast();
  final StreamController<String> _errorNotificationController =
      StreamController<String>.broadcast();
  final StreamController<bool> _retryStateController =
      StreamController<bool>.broadcast();
  final StreamController<String?> _titleController =
      StreamController<String?>.broadcast();
  final StreamController<Duration> _bufferController =
      StreamController<Duration>.broadcast();

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
  Stream<String> get errorNotificationStream =>
      _errorNotificationController.stream;
  Stream<bool> get retryStateStream => _retryStateController.stream;
  Stream<AudioState> get audioStateStream => _audioService.stateStream;
  Stream<String> get audioErrorStream => _audioService.errorStream;
  Stream<String?> get titleStream => _titleController.stream;
  Stream<Duration> get bufferStream => _bufferController.stream;
  Stream<String> get connectionQualityStream =>
      _audioService.connectionQualityStream;
  Stream<int> get pingStream => _networkService.pingStream;
  int get reconnectCount => _networkService.reconnectCount;
  NetworkService get networkService => _networkService;

  String? get currentToken => _currentToken;
  bool get isConnected => _currentToken != null && _currentConfig != null;
  bool get isRetrying => _isRetrying;
  AudioState get audioState => _audioService.currentState;

  void _setRetryState(bool isRetrying) {
    if (_isRetrying != isRetrying) {
      _isRetrying = isRetrying;
      _retryStateController.add(_isRetrying);
      Logger.info('RadioController: Retry state changed to: $_isRetrying');
    }
  }

  Future<void> _initialize() async {
    _apiService = ApiService();
    _storageService = await StorageService.getInstance();
    _audioService = await AudioService.getInstance();
    _networkService = NetworkService.getInstance();

    _currentToken = _storageService.getToken();
    Logger.info(
        'RadioController: Loaded token from storage: ${_currentToken != null ? '[PRESENT]' : '[MISSING]'}');
    _tokenController.add(_currentToken);

    // Always set initial connection status to false
    // Stream config will be fetched from API on connection
    _connectionStatusController.add(false);

    _setupAudioErrorHandling();
    _setupAudioStateHandling();
    _setupBufferMonitoring();
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

      // DEBOUNCED RECONNECTION: Use debounced reconnection for audio errors
      if (_currentToken != null && _currentConfig != null && !_isRetrying) {
        _triggerReconnection('Audio error: $error');
      }
    });
  }

  void _setupAudioStateHandling() {
    _audioService.stateStream.listen((state) {
      Logger.info('🎛️ CONTROLLER_DEBUG: Audio state changed to $state',
          'RadioController');
      Logger.debug(
          '🎛️ CONTROLLER_DEBUG: Timestamp: ${DateTime.now().toIso8601String()}',
          'RadioController');
      Logger.debug(
          '🎛️ CONTROLLER_DEBUG: Current token: ${_currentToken != null ? '[PRESENT]' : '[MISSING]'}',
          'RadioController');
      Logger.debug(
          '🎛️ CONTROLLER_DEBUG: Current config: ${_currentConfig != null ? '[PRESENT]' : '[MISSING]'}',
          'RadioController');
      Logger.debug(
          '🎛️ CONTROLLER_DEBUG: Is retrying: $_isRetrying', 'RadioController');
      Logger.debug(
          '🎛️ CONTROLLER_DEBUG: Auto connect enabled: $_autoConnectEnabled',
          'RadioController');
      Logger.debug('🎛️ CONTROLLER_DEBUG: Stream healthy: $_isStreamHealthy',
          'RadioController');
      Logger.debug(
          '🎛️ CONTROLLER_DEBUG: Consecutive failures: $_consecutiveFailures',
          'RadioController');

      switch (state) {
        case AudioState.playing:
          Logger.info(
              '🎛️ CONTROLLER_DEBUG: Stream PLAYING - updating status and resetting retry state',
              'RadioController');
          _statusMessageController.add('Playing');
          _setRetryState(false);
          _isStreamHealthy = true;
          _consecutiveFailures = 0;
          _lastStreamStart = DateTime.now();
          Logger.info(
              'RadioController: Stream playing successfully - audio state is genuinely playing');
          break;

        case AudioState.loading:
        case AudioState.buffering:
          Logger.warning(
              '🎛️ CONTROLLER_DEBUG: Stream is ${state == AudioState.loading ? 'LOADING' : 'BUFFERING'} - setting up timeout monitoring',
              'RadioController');
          if (state == AudioState.buffering) {
            _statusMessageController.add('Buffering...');
          } else {
            _statusMessageController.add('Loading...');
          }
          _handleLoadingBufferingTimeout();
          break;

        case AudioState.error:
          Logger.error(
              '🎛️ CONTROLLER_DEBUG: Audio state changed to ERROR - triggering reconnection if needed',
              'RadioController');
          _isStreamHealthy = false;
          if (_currentToken != null && _currentConfig != null && !_isRetrying) {
            Logger.warning(
                '🎛️ CONTROLLER_DEBUG: Triggering reconnection due to audio error',
                'RadioController');
            _triggerReconnection('Stream error');
          } else {
            Logger.debug(
                '🎛️ CONTROLLER_DEBUG: Not triggering reconnection - missing token/config or already retrying',
                'RadioController');
          }
          break;

        case AudioState.idle:
          Logger.warning('🎛️ CONTROLLER_DEBUG: Audio state changed to IDLE',
              'RadioController');
          _isStreamHealthy = false;
          break;

        case AudioState.paused:
          Logger.info('🎛️ CONTROLLER_DEBUG: Audio state changed to PAUSED',
              'RadioController');
          _statusMessageController.add('Paused');
          break;
      }
    });
  }

  void _setupBufferMonitoring() {
    _audioService.bufferStream.listen((bufferAhead) {
      // Forward buffer info to UI
      _bufferController.add(bufferAhead);

      _currentBufferSize = bufferAhead;

      // Track zero buffer time for hang detection
      if (bufferAhead.inSeconds == 0) {
        _zeroBufferStartTime ??= DateTime.now();
      } else {
        _zeroBufferStartTime = null; // Reset if buffer is not zero
      }

      Logger.debug('RadioController: Buffer ahead: ${bufferAhead.inSeconds}s',
          'RadioController');
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
    Logger.debug(
        '🎛️ TIMEOUT_DEBUG: Setting up 20-second timeout for loading/buffering state',
        'RadioController');
    Logger.debug(
        '🎛️ TIMEOUT_DEBUG: Current time: ${DateTime.now().toIso8601String()}',
        'RadioController');

    Timer(const Duration(seconds: 20), () {
      final currentAudioState = _audioService.currentState;
      Logger.debug(
          '🎛️ TIMEOUT_DEBUG: 20-second timeout triggered, checking current state...',
          'RadioController');
      Logger.debug('🎛️ TIMEOUT_DEBUG: Current audio state: $currentAudioState',
          'RadioController');
      Logger.debug(
          '🎛️ TIMEOUT_DEBUG: Current config: ${_currentConfig != null ? '[PRESENT]' : '[MISSING]'}',
          'RadioController');
      Logger.debug(
          '🎛️ TIMEOUT_DEBUG: Is retrying: $_isRetrying', 'RadioController');

      if ((currentAudioState == AudioState.loading ||
              currentAudioState == AudioState.buffering) &&
          _currentConfig != null &&
          !_isRetrying) {
        Logger.warning(
            '🎛️ TIMEOUT_DEBUG: Stream timeout after 20 seconds - triggering aggressive reconnection',
            'RadioController');
        Logger.warning(
            '🎛️ TIMEOUT_DEBUG: This rapid timeout helps catch hanging streams early',
            'RadioController');
        _triggerReconnection(
            'Stream ${currentAudioState.toString()} timeout after 20s');
      } else {
        Logger.debug(
            '🎛️ TIMEOUT_DEBUG: Timeout conditions not met - no action taken',
            'RadioController');
        Logger.debug(
            '🎛️ TIMEOUT_DEBUG: Audio state is loading/buffering: ${(currentAudioState == AudioState.loading || currentAudioState == AudioState.buffering)}',
            'RadioController');
        Logger.debug('🎛️ TIMEOUT_DEBUG: Has config: ${_currentConfig != null}',
            'RadioController');
        Logger.debug('🎛️ TIMEOUT_DEBUG: Not retrying: ${!_isRetrying}',
            'RadioController');
      }
    });
  }

  void _startStreamHealthMonitoring() {
    _streamHealthTimer?.cancel();
    _streamHealthTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      await _checkStreamHealth();
      // MONITOR CONNECTIONS: Log active connections every 15 seconds
      ConnectionMonitor.logActiveConnections();
    });
  }

  Future<void> _checkStreamHealth() async {
    if (_currentToken == null || _currentConfig == null) return;

    final now = DateTime.now();
    final audioState = _audioService.currentState;

    // Log comprehensive diagnostic information every health check
    Logger.logDiagnosticInfo(
      'HEALTH_CHECK',
      audioState: audioState.toString(),
      networkState: _networkService.isConnected ? 'CONNECTED' : 'DISCONNECTED',
      controllerState:
          'token=${_currentToken != null}, config=${_currentConfig != null}, retrying=$_isRetrying, healthy=$_isStreamHealthy',
      bufferSeconds: _currentBufferSize.inSeconds,
      pingMs: null, // Will be updated from ping stream
      isRetrying: _isRetrying,
      currentToken: _currentToken,
      streamUrl: _currentConfig?.streamUrl,
    );

    // Check if stream has been in an unhealthy state for too long
    if (!_isStreamHealthy &&
        _lastStreamStart != null &&
        now.difference(_lastStreamStart!).inMinutes > 3) {
      Logger.warning('🎛️ HEALTH_DEBUG: Stream unhealthy for over 3 minutes',
          'RadioController');
      if (!_isRetrying) {
        Logger.warning(
            '🎛️ HEALTH_DEBUG: Triggering force reconnection due to prolonged unhealthy state',
            'RadioController');
        await forceReconnect();
        return;
      }
    }

    // Check if we're stuck in loading/buffering states - this is the main issue
    if ((audioState == AudioState.loading ||
            audioState == AudioState.buffering) &&
        _lastStreamStart != null) {
      final timeSinceStart = now.difference(_lastStreamStart!);

      if (timeSinceStart.inMinutes > 2) {
        Logger.error(
            '🎛️ HEALTH_DEBUG: Stream stuck in ${audioState.toString()} for over 2 minutes!',
            'RadioController');
        Logger.error(
            '🎛️ HEALTH_DEBUG: This is the main hanging issue - using aggressive reconnection',
            'RadioController');
        Logger.error(
            '🎛️ HEALTH_DEBUG: Stream URL: ${_currentConfig?.streamUrl}',
            'RadioController');
        Logger.error(
            '🎛️ HEALTH_DEBUG: Network state: ${_networkService.isConnected ? 'CONNECTED' : 'DISCONNECTED'}',
            'RadioController');

        // Use aggressive reconnection for stuck streams over 2 minutes
        await forceReconnect();
        return;
      } else if (timeSinceStart.inSeconds > 45) {
        Logger.warning(
            '🎛️ HEALTH_DEBUG: Stream stuck in ${audioState.toString()} for over 45 seconds',
            'RadioController');
        Logger.warning(
            '🎛️ HEALTH_DEBUG: This indicates potential hanging - triggering standard reconnection',
            'RadioController');
        if (!_isRetrying) {
          _triggerReconnection(
              'Stream stuck in ${audioState.toString()} for over 45 seconds');
        }
      }
    }

    // Check for idle state when we should be playing
    if (audioState == AudioState.idle &&
        _currentConfig != null &&
        _autoConnectEnabled &&
        !_isRetrying) {
      Logger.warning(
          '🎛️ HEALTH_DEBUG: Stream is idle but should be playing - triggering reconnection',
          'RadioController');
      _triggerReconnection('Stream unexpectedly idle');
    }

    // Check for error state
    if (audioState == AudioState.error && !_isRetrying) {
      Logger.error(
          '🎛️ HEALTH_DEBUG: Stream in error state - triggering reconnection',
          'RadioController');
      _triggerReconnection('Stream in error state');
    }

    // Check for zero buffer for too long - indicates potential hang
    if (_zeroBufferStartTime != null &&
        audioState == AudioState.playing &&
        now.difference(_zeroBufferStartTime!).inSeconds > 30) {
      Logger.warning(
          '🎛️ HEALTH_DEBUG: Zero buffer for over 30 seconds while playing - potential hang',
          'RadioController');
      Logger.warning(
          '🎛️ HEALTH_DEBUG: This indicates stream data flow has stopped',
          'RadioController');
      if (!_isRetrying) {
        _triggerReconnection('Zero buffer detected for over 30 seconds');
      }
    }
  }

  void _triggerReconnection(String reason) {
    Logger.info(
        '🔄 RECONNECT_DEBUG: Reconnection trigger called with reason: $reason',
        'RadioController');
    Logger.debug(
        '🔄 RECONNECT_DEBUG: Current timestamp: ${DateTime.now().toIso8601String()}',
        'RadioController');
    Logger.debug(
        '🔄 RECONNECT_DEBUG: Is retrying: $_isRetrying', 'RadioController');
    Logger.debug(
        '🔄 RECONNECT_DEBUG: Last reconnection request: $_lastReconnectionRequest',
        'RadioController');
    Logger.debug(
        '🔄 RECONNECT_DEBUG: Pending reconnection reason: $_pendingReconnectionReason',
        'RadioController');

    if (_isRetrying) {
      Logger.debug(
          '🔄 RECONNECT_DEBUG: Reconnection already in progress, ignoring: $reason',
          'RadioController');
      return;
    }

    // DEBOUNCING: Prevent rapid reconnection requests
    final now = DateTime.now();
    if (_lastReconnectionRequest != null &&
        now.difference(_lastReconnectionRequest!) <
            _reconnectionDebounceDelay) {
      final timeSinceLastRequest = now.difference(_lastReconnectionRequest!);
      Logger.warning(
          '🔄 RECONNECT_DEBUG: Reconnection debounced (${timeSinceLastRequest.inSeconds}s ago), reason: $reason',
          'RadioController');
      Logger.debug(
          '🔄 RECONNECT_DEBUG: Debounce delay: ${_reconnectionDebounceDelay.inSeconds}s',
          'RadioController');
      _pendingReconnectionReason = reason;
      Logger.debug(
          '🔄 RECONNECT_DEBUG: Set pending reconnection reason: $reason',
          'RadioController');
      return;
    }

    _lastReconnectionRequest = now;
    _pendingReconnectionReason = null;
    Logger.debug('🔄 RECONNECT_DEBUG: Updated last reconnection request time',
        'RadioController');
    Logger.debug('🔄 RECONNECT_DEBUG: Cleared pending reconnection reason',
        'RadioController');

    Logger.info('🔄 RECONNECT_DEBUG: Triggering reconnection - $reason',
        'RadioController');
    _autoConnectEnabled = true;
    _retryAttempts = 0;
    Logger.debug('🔄 RECONNECT_DEBUG: Set auto connect enabled: true',
        'RadioController');
    Logger.debug(
        '🔄 RECONNECT_DEBUG: Reset retry attempts to: 0', 'RadioController');

    // Cancel existing debounce timer if any
    if (_reconnectionDebounceTimer != null) {
      Logger.debug('🔄 RECONNECT_DEBUG: Cancelling existing debounce timer',
          'RadioController');
      _reconnectionDebounceTimer?.cancel();
    }

    Logger.debug('🔄 RECONNECT_DEBUG: About to call _attemptConnection()',
        'RadioController');
    _attemptConnection();
  }

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

      final config = await _apiService.getStreamConfig(token);
      if (config != null) {
        _currentToken = token;
        _currentConfig = config;
        _titleController.add(config.title);

        await _storageService.saveToken(token);
        await _storageService.saveLastVolume(config.volume);

        _networkService.setStreamHost(config.streamUrl);
        _networkService.resetReconnectCount();

        _tokenController.add(_currentToken);
        Logger.info('RadioController: Broadcasting connection status: true');
        _connectionStatusController.add(true);

        // Don't set "Connected successfully" yet - wait for audio to start
        _statusMessageController.add('Starting audio stream...');

        _startConfigPolling();

        try {
          await _audioService.playStream(config);
          _lastStreamStart = DateTime.now();

          // Don't set status here - let audio state handling manage the status
          // The _setupAudioStateHandling will set "Playing" when audio actually starts
          Logger.info(
              'RadioController: playStream call completed, waiting for audio state change');
        } catch (e) {
          Logger.error('RadioController: Failed to start audio stream: $e');
          _statusMessageController.add('Audio stream failed to start');
          _triggerReconnection(
              'Failed to start audio after successful API connection');
          return true; // API connection was successful
        }

        // Enable auto-reconnection and start config polling after successful connection
        _autoConnectEnabled = true;

        // Reset retry state on success
        _retryAttempts = 0;
        _consecutiveFailures = 0;
        _setRetryState(false);

        return true;
      } else {
        throw Exception('Invalid configuration received from API');
      }
    } catch (e) {
      Logger.error('RadioController: Connection failed: $e');
      _connectionStatusController.add(false);

      // Handle different types of errors
      if (e is ApiError && e.isFromBackend) {
        // Show backend error message in snackbar
        _errorNotificationController.add(e.message);
        _statusMessageController.add('Connection failed');
      } else {
        // Show generic error in status and snackbar
        final errorMessage = e.toString();
        _statusMessageController.add('Connection failed: $errorMessage');
        _errorNotificationController.add(errorMessage);
      }

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
    _titleController.add(null);
  }

  Future<void> playPause() async {
    if (_audioService.currentState == AudioState.playing) {
      await _audioService.pause();
    } else if (_audioService.currentState == AudioState.paused ||
        _audioService.currentState == AudioState.idle) {
      if (_currentConfig != null) {
        _lastStreamStart = DateTime.now();
        // SAFE PLAYSTREAM: Use mutex-protected playStream method
        await _audioService.playStream(_currentConfig!);
      } else {
        Logger.info(
            'RadioController: No config available for playPause, refreshing...');
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

      // CENTRALIZED RECONNECTION: Use the debounced reconnection system
      _triggerReconnection('Manual reconnect requested');
    } else {
      Logger.warning('RadioController: Cannot reconnect - no token available');
      _statusMessageController.add('No connection token available');
    }
  }

  /// Force reconnect with aggressive cleanup - use when stream is stuck
  Future<void> forceReconnect() async {
    if (_currentToken != null && _currentToken!.isNotEmpty) {
      Logger.warning(
          'RadioController: Force reconnect triggered - aggressive cleanup');
      _statusMessageController.add('Force reconnecting...');

      // Stop all timers and reset state
      _configCheckTimer?.cancel();
      _retryTimer?.cancel();
      _reconnectionDebounceTimer?.cancel();

      // Force stop audio service
      await _audioService.stop();

      // Reset all state
      _isRetrying = false;
      _isStreamHealthy = false;
      _retryAttempts = 0;
      _lastReconnectionRequest = null;
      _pendingReconnectionReason = null;

      // Wait a bit for cleanup
      await Future.delayed(const Duration(milliseconds: 1000));

      // Trigger immediate reconnection
      _autoConnectEnabled = true;
      _attemptConnection();
    } else {
      Logger.warning(
          'RadioController: Cannot force reconnect - no token available');
      _statusMessageController.add('No connection token available');
    }
  }

  void _startConfigPolling() {
    Logger.info('🔄 POLLING_DEBUG: Starting config polling (every 30 seconds)',
        'RadioController');
    _configCheckTimer?.cancel();
    _configCheckTimer = Timer.periodic(const Duration(seconds: 60), (_) async {
      Logger.info(
          '🔄 POLLING_DEBUG: Config polling timer triggered - refreshing config',
          'RadioController');
      await _refreshConfig();
    });
  }

  Future<void> _refreshConfig() async {
    Logger.info(
        '🔄 POLLING_DEBUG: _refreshConfig() called - starting API request',
        'RadioController');

    if (_currentToken == null) {
      Logger.warning(
          '🔄 POLLING_DEBUG: No token available, skipping config refresh',
          'RadioController');
      return;
    }

    try {
      Logger.info(
          '🔄 POLLING_DEBUG: Making API call to getStreamConfig with token: ${_currentToken!.substring(0, 2)}****',
          'RadioController');
      final requestStartTime = DateTime.now();

      final newConfig = await _apiService.getStreamConfig(_currentToken!);

      final requestDuration = DateTime.now().difference(requestStartTime);
      Logger.info(
          '🔄 POLLING_DEBUG: API request completed in ${requestDuration.inMilliseconds}ms',
          'RadioController');

      if (newConfig != null) {
        Logger.info(
            '🔄 POLLING_DEBUG: Received config from API - URL: ${newConfig.streamUrl}',
            'RadioController');
        Logger.info(
            '🔄 POLLING_DEBUG: Current config URL: ${_currentConfig?.streamUrl}',
            'RadioController');

        // Check if stream URL has changed
        final streamUrlChanged = _currentConfig == null ||
            _currentConfig!.streamUrl != newConfig.streamUrl;

        if (streamUrlChanged) {
          Logger.info(
              'RadioController: Stream URL changed from ${_currentConfig?.streamUrl} to ${newConfig.streamUrl}');
          _currentConfig = newConfig;
          _titleController.add(newConfig.title);
          await _storageService.saveLastVolume(newConfig.volume);

          // Always stop and restart with new stream URL
          Logger.info(
              'RadioController: Stopping current stream and starting with new URL');
          await _audioService.stop();
          _lastStreamStart = DateTime.now();

          try {
            await _audioService.playStream(newConfig);
            _statusMessageController.add('Stream restarted with new URL');
          } catch (e) {
            Logger.error(
                'RadioController: Failed to start stream with new URL: $e');
            _triggerReconnection('Failed to start stream with new URL');
          }
        } else if (_currentConfig != newConfig) {
          // Other config changes (volume, title, etc.)
          Logger.info('RadioController: Config updated (non-URL changes)');
          _currentConfig = newConfig;
          _titleController.add(newConfig.title);
          await _storageService.saveLastVolume(newConfig.volume);
          _statusMessageController.add('Stream config updated');
        } else {
          Logger.info('🔄 POLLING_DEBUG: Config unchanged - no updates needed',
              'RadioController');
        }
      } else {
        Logger.warning(
            '🔄 POLLING_DEBUG: API returned null config', 'RadioController');
      }
    } catch (e) {
      Logger.error(
          '🔄 POLLING_DEBUG: API request failed: $e', 'RadioController');
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

      // Always fetch fresh config from API - no local stream_url restoration
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
    Logger.debug(
        '🔗 ATTEMPT_DEBUG: _attemptConnection called', 'RadioController');
    Logger.debug('🔗 ATTEMPT_DEBUG: Auto connect enabled: $_autoConnectEnabled',
        'RadioController');
    Logger.debug(
        '🔗 ATTEMPT_DEBUG: Current token: ${_currentToken != null ? '[PRESENT]' : '[MISSING]'}',
        'RadioController');
    Logger.debug(
        '🔗 ATTEMPT_DEBUG: Token empty: ${_currentToken?.isEmpty ?? 'null'}',
        'RadioController');

    if (!_autoConnectEnabled ||
        _currentToken == null ||
        _currentToken!.isEmpty) {
      Logger.warning(
          '🔗 ATTEMPT_DEBUG: Early return - conditions not met for connection attempt',
          'RadioController');
      Logger.debug(
          '🔗 ATTEMPT_DEBUG: Auto connect enabled: $_autoConnectEnabled',
          'RadioController');
      Logger.debug('🔗 ATTEMPT_DEBUG: Has token: ${_currentToken != null}',
          'RadioController');
      Logger.debug(
          '🔗 ATTEMPT_DEBUG: Token not empty: ${_currentToken?.isNotEmpty ?? false}',
          'RadioController');
      return;
    }

    Logger.info(
        '🔗 ATTEMPT_DEBUG: Starting connection attempt', 'RadioController');
    _setRetryState(true);
    _retryAttempts++;
    _networkService.incrementReconnectCount();
    Logger.debug(
        '🔗 ATTEMPT_DEBUG: Retry attempts incremented to: $_retryAttempts',
        'RadioController');
    Logger.debug(
        '🔗 ATTEMPT_DEBUG: Network reconnect count: ${_networkService.reconnectCount}',
        'RadioController');

    Logger.info('RadioController: Connection attempt #$_retryAttempts');

    Logger.debug(
        '🔗 ATTEMPT_DEBUG: Checking internet connection...', 'RadioController');
    final hasInternet = await _networkService.checkInternetConnection();
    Logger.debug(
        '🔗 ATTEMPT_DEBUG: Internet connection check result: $hasInternet',
        'RadioController');

    if (!hasInternet) {
      Logger.warning(
          '🔗 ATTEMPT_DEBUG: No internet connection detected - scheduling retry',
          'RadioController');
      _statusMessageController.add(
          'No internet connection (attempt $_retryAttempts) - retrying...');
      _scheduleRetry();
      return;
    }

    Logger.debug(
        '🔗 ATTEMPT_DEBUG: Internet connection OK, proceeding with connection',
        'RadioController');
    _statusMessageController.add('Connecting (attempt $_retryAttempts)...');

    // Use the unified connect method with retry flag
    Logger.debug('🔗 ATTEMPT_DEBUG: Calling connect() with retry flag...',
        'RadioController');
    final connectStartTime = DateTime.now();
    final success = await connect(_currentToken!, isRetry: true);
    final connectDuration = DateTime.now().difference(connectStartTime);
    Logger.debug(
        '🔗 ATTEMPT_DEBUG: connect() completed in ${connectDuration.inMilliseconds}ms with result: $success',
        'RadioController');

    if (success) {
      // Connection successful - stop retrying
      Logger.info(
          '🔗 ATTEMPT_DEBUG: Connection successful - cleaning up retry state',
          'RadioController');
      _retryTimer?.cancel();
      _setRetryState(false);
      Logger.info(
          'RadioController: Auto-connect successful after $_retryAttempts attempts');

      // PROCESS PENDING RECONNECTIONS: Check if there were any pending reconnection requests
      if (_pendingReconnectionReason != null) {
        Logger.info(
            '🔗 ATTEMPT_DEBUG: Processing pending reconnection: $_pendingReconnectionReason',
            'RadioController');
        final pendingReason = _pendingReconnectionReason!;
        _pendingReconnectionReason = null;

        // Schedule pending reconnection with a small delay
        Logger.debug(
            '🔗 ATTEMPT_DEBUG: Scheduling pending reconnection with 2s delay',
            'RadioController');
        _reconnectionDebounceTimer = Timer(const Duration(seconds: 2), () {
          Logger.debug(
              '🔗 ATTEMPT_DEBUG: Executing delayed pending reconnection',
              'RadioController');
          _triggerReconnection(pendingReason);
        });
      } else {
        Logger.debug('🔗 ATTEMPT_DEBUG: No pending reconnection requests',
            'RadioController');
      }
    } else {
      // Connection failed - schedule retry
      Logger.error(
          '🔗 ATTEMPT_DEBUG: Connection attempt $_retryAttempts failed - scheduling retry',
          'RadioController');
      Logger.error(
          'RadioController: Connection attempt $_retryAttempts failed');
      _statusMessageController
          .add('Connection failed (attempt $_retryAttempts) - retrying...');
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (!_autoConnectEnabled) {
      _setRetryState(false);
      return;
    }

    _retryTimer?.cancel();

    // Adaptive delay based on failure count and attempt number
    int delay = 10;
    // if (_retryAttempts <= 5) {
    //   delay = _retryAttempts * 3; // 3, 6, 9, 12, 15 seconds
    // } else if (_retryAttempts <= 10) {
    //   delay = 30; // 30 seconds for attempts 6-10
    // } else if (_retryAttempts <= 20) {
    //   delay = 60; // 1 minute for attempts 11-20
    // } else {
    //   delay = 300; // 5 minutes for attempts 21+
    // }

    // // Increase delay if we have many consecutive failures
    // if (_consecutiveFailures > 10) {
    //   delay = delay * 2; // Double the delay
    // }

    Logger.info(
        'RadioController: Scheduling retry #${_retryAttempts + 1} in ${delay}s (consecutive failures: $_consecutiveFailures)');

    _retryTimer = Timer(Duration(seconds: delay), () {
      if (_autoConnectEnabled) {
        _attemptConnection();
      } else {
        _setRetryState(false);
      }
    });
  }

  Future<void> dispose() async {
    Logger.info('RadioController: Disposing');
    _autoConnectEnabled = false;
    _configCheckTimer?.cancel();
    _retryTimer?.cancel();
    _streamHealthTimer?.cancel();
    _reconnectionDebounceTimer?.cancel(); // Cancel debounce timer
    _networkService.stopMonitoring();
    await _audioService.dispose();
    await _tokenController.close();
    await _connectionStatusController.close();
    await _statusMessageController.close();
    await _errorNotificationController.close();
    await _retryStateController.close();
    await _titleController.close();
  }
}
