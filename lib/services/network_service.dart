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
    try {
      final result = await InternetAddress.lookup('google.com');
      final isConnected = result.isNotEmpty && result[0].rawAddress.isNotEmpty;

      if (_lastConnectivityState != isConnected) {
        _lastConnectivityState = isConnected;
        _connectivityController.add(isConnected);
        Logger.info('NetworkService: Connectivity changed to: $isConnected');
      }
    } catch (e) {
      if (_lastConnectivityState != false) {
        _lastConnectivityState = false;
        _connectivityController.add(false);
        Logger.info('NetworkService: No internet connection');
      }
    }
  }

  Future<void> _measurePing() async {
    if (_streamHost == null || !_lastConnectivityState) {
      return;
    }

    try {
      final stopwatch = Stopwatch()..start();
      final result = await InternetAddress.lookup(_streamHost!);

      if (result.isNotEmpty) {
        final socket = await Socket.connect(result.first, 80,
            timeout: const Duration(seconds: 5));
        await socket.close();
        stopwatch.stop();

        final pingMs = stopwatch.elapsedMilliseconds;
        _pingController.add(pingMs);
        Logger.debug('NetworkService: Ping to $_streamHost: ${pingMs}ms');
      }
    } catch (e) {
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
