import 'dart:async';
import 'dart:io';
import '../utils/logger.dart';

class NetworkService {
  static NetworkService? _instance;

  final StreamController<bool> _connectivityController =
      StreamController<bool>.broadcast();

  Timer? _connectivityTimer;
  bool _lastConnectivityState = false;

  NetworkService._();

  static NetworkService getInstance() {
    _instance ??= NetworkService._();
    return _instance!;
  }

  Stream<bool> get connectivityStream => _connectivityController.stream;

  bool get isConnected => _lastConnectivityState;

  void startMonitoring() {
    _connectivityTimer?.cancel();
    _connectivityTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _checkConnectivity();
    });

    // Check immediately
    _checkConnectivity();
  }

  void stopMonitoring() {
    _connectivityTimer?.cancel();
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
  }
}
