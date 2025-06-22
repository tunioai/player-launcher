import 'dart:async';
import 'dart:io';
import '../utils/logger.dart';

class NetworkService {
  static NetworkService? _instance;

  final StreamController<bool> _connectivityController =
      StreamController<bool>.broadcast();
  final StreamController<int> _pingController =
      StreamController<int>.broadcast();

  Timer? _connectivityTimer;
  Timer? _pingTimer;
  bool _lastConnectivityState = false;
  int _reconnectCount = 0;
  String? _streamHost;

  NetworkService._();

  static NetworkService getInstance() {
    _instance ??= NetworkService._();
    return _instance!;
  }

  Stream<bool> get connectivityStream => _connectivityController.stream;
  Stream<int> get pingStream => _pingController.stream;

  bool get isConnected => _lastConnectivityState;
  int get reconnectCount => _reconnectCount;

  void setStreamHost(String streamUrl) {
    try {
      final uri = Uri.parse(streamUrl);
      _streamHost = uri.host;
      Logger.info('NetworkService: Stream host set to: $_streamHost');
    } catch (e) {
      Logger.error('NetworkService: Failed to parse stream URL: $e');
      _streamHost = null;
    }
  }

  void incrementReconnectCount() {
    _reconnectCount++;
    Logger.info(
        'NetworkService: Reconnect count increased to: $_reconnectCount');
  }

  void resetReconnectCount() {
    _reconnectCount = 0;
    Logger.info('NetworkService: Reconnect count reset');
  }

  void startMonitoring() {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkConnectivity();
    });

    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _measurePing();
    });

    _checkConnectivity();
    _measurePing();
  }

  void stopMonitoring() {
    _connectivityTimer?.cancel();
    _pingTimer?.cancel();
  }

  Future<void> _checkConnectivity() async {
    Logger.debug(
        '🌐 NET_DEBUG: Starting connectivity check...', 'NetworkService');
    try {
      final lookupStartTime = DateTime.now();
      final result = await InternetAddress.lookup('google.com');
      final lookupDuration = DateTime.now().difference(lookupStartTime);

      Logger.debug(
          '🌐 NET_DEBUG: DNS lookup completed in ${lookupDuration.inMilliseconds}ms',
          'NetworkService');
      Logger.debug('🌐 NET_DEBUG: DNS lookup result count: ${result.length}',
          'NetworkService');

      final isConnected = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
      Logger.debug(
          '🌐 NET_DEBUG: Connectivity result: $isConnected', 'NetworkService');

      if (_lastConnectivityState != isConnected) {
        Logger.info(
            '🌐 NET_DEBUG: Connectivity state changed from $_lastConnectivityState to $isConnected',
            'NetworkService');
        _lastConnectivityState = isConnected;
        _connectivityController.add(isConnected);
        Logger.info('NetworkService: Connectivity changed to: $isConnected');
      } else {
        Logger.debug('🌐 NET_DEBUG: Connectivity state unchanged: $isConnected',
            'NetworkService');
      }
    } catch (e) {
      Logger.debug(
          '🌐 NET_DEBUG: Connectivity check failed: $e', 'NetworkService');
      if (_lastConnectivityState != false) {
        Logger.warning(
            '🌐 NET_DEBUG: Setting connectivity to false due to error',
            'NetworkService');
        _lastConnectivityState = false;
        _connectivityController.add(false);
        Logger.info('NetworkService: No internet connection');
      }
    }
  }

  Future<void> _measurePing() async {
    Logger.debug(
        '🌐 PING_DEBUG: Starting ping measurement...', 'NetworkService');
    Logger.debug('🌐 PING_DEBUG: Stream host: $_streamHost', 'NetworkService');
    Logger.debug(
        '🌐 PING_DEBUG: Last connectivity state: $_lastConnectivityState',
        'NetworkService');

    if (_streamHost == null || !_lastConnectivityState) {
      Logger.debug(
          '🌐 PING_DEBUG: Skipping ping - no stream host or no connectivity',
          'NetworkService');
      return;
    }

    try {
      Logger.debug('🌐 PING_DEBUG: Starting DNS lookup for $_streamHost...',
          'NetworkService');
      final stopwatch = Stopwatch()..start();
      final result = await InternetAddress.lookup(_streamHost!);

      if (result.isNotEmpty) {
        Logger.debug('🌐 PING_DEBUG: DNS resolved to: ${result.first.address}',
            'NetworkService');
        Logger.debug(
            '🌐 PING_DEBUG: Attempting socket connection...', 'NetworkService');

        final socket = await Socket.connect(result.first, 80,
            timeout: const Duration(seconds: 5));
        await socket.close();
        stopwatch.stop();

        final pingMs = stopwatch.elapsedMilliseconds;
        Logger.debug(
            '🌐 PING_DEBUG: Socket connection successful', 'NetworkService');
        Logger.debug(
            '🌐 PING_DEBUG: Ping measurement: ${pingMs}ms', 'NetworkService');

        _pingController.add(pingMs);
        Logger.debug('NetworkService: Ping to $_streamHost: ${pingMs}ms');

        // Alert on high ping
        if (pingMs > 500) {
          Logger.warning('🌐 PING_DEBUG: HIGH PING detected: ${pingMs}ms',
              'NetworkService');
        }
      } else {
        Logger.error('🌐 PING_DEBUG: DNS lookup returned empty result',
            'NetworkService');
      }
    } catch (e) {
      Logger.debug(
          '🌐 PING_DEBUG: Ping measurement failed: $e', 'NetworkService');
      Logger.debug('NetworkService: Ping measurement failed: $e');
    }
  }

  Future<bool> checkInternetConnection() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  Future<bool> waitForConnection({int maxWaitSeconds = 300}) async {
    final completer = Completer<bool>();
    Timer? timeoutTimer;
    StreamSubscription? subscription;

    // Check current state
    if (await checkInternetConnection()) {
      return true;
    }

    // Wait for connection to appear
    subscription = connectivityStream.listen((isConnected) {
      if (isConnected) {
        timeoutTimer?.cancel();
        subscription?.cancel();
        if (!completer.isCompleted) {
          completer.complete(true);
        }
      }
    });

    // Timeout
    timeoutTimer = Timer(Duration(seconds: maxWaitSeconds), () {
      subscription?.cancel();
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    });

    startMonitoring();
    return completer.future;
  }

  void dispose() {
    _connectivityTimer?.cancel();
    _connectivityController.close();
    _pingTimer?.cancel();
    _pingController.close();
  }
}
