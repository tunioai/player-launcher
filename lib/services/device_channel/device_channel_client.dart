import 'dart:async';
import 'dart:io';

import '../../utils/logger.dart';
import 'device_channel_protocol.dart';

typedef SpotHandler = Future<void> Function(Map<String, dynamic> body);
typedef SocketConnector = Future<WebSocket> Function(
    Uri url, Map<String, String> headers);

final class DeviceChannelClient {
  static const String _tag = 'DeviceChannel';
  static const Duration pingInterval = Duration(seconds: 20);

  final Uri url;
  final String pin;
  final String deviceId;
  final String appVersion;
  final Map<String, String> extraHeaders;
  final SpotHandler onSpot;
  final ReconnectBackoff _backoff;
  final SocketConnector _connect;
  final SpotSequenceGuard _sequence = SpotSequenceGuard();
  final StreamController<bool> _connection = StreamController<bool>.broadcast();

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  Completer<void>? _reconnectWait;
  bool _running = false;
  bool _connected = false;

  DeviceChannelClient({
    required this.url,
    required this.pin,
    required this.deviceId,
    required this.appVersion,
    required this.onSpot,
    this.extraHeaders = const {},
    ReconnectBackoff? backoff,
    SocketConnector? connector,
  })  : _backoff = backoff ?? ReconnectBackoff(),
        _connect = connector ?? _defaultConnector;

  static Future<WebSocket> _defaultConnector(
      Uri url, Map<String, String> headers) {
    return WebSocket.connect(url.toString(), headers: headers);
  }

  bool get isConnected => _connected;
  bool get isRunning => _running;

  Stream<bool> get connectionStream => _connection.stream;

  void start() {
    if (_running) return;
    _running = true;
    _unawaited(_loop());
  }

  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _releaseWait();
    await _closeSocket();
  }

  void nudge() {
    if (!_running || _connected) return;
    _backoff.reset();
    _releaseWait();
  }

  Future<void> dispose() async {
    await stop();
    await _connection.close();
  }

  Future<void> _loop() async {
    while (_running) {
      final opened = await _openOnce();
      if (!_running) break;
      if (!opened) {
        await _waitBeforeRetry();
        continue;
      }
      await _waitBeforeRetry();
    }
  }

  Future<bool> _openOnce() async {
    final headers = <String, String>{
      'Authorization': 'Bearer $pin',
      ...extraHeaders,
    };

    final WebSocket socket;
    try {
      socket = await _connect(url, headers);
    } catch (error) {
      Logger.warning('Channel connect failed: $error', _tag);
      return false;
    }
    if (!_running) {
      await socket.close();
      return false;
    }

    _socket = socket;
    _sequence.reset();
    _backoff.reset();
    socket.pingInterval = pingInterval;
    _setConnected(true);
    Logger.info('Channel connected to $url', _tag);

    _send(helloFrame(deviceId: deviceId, version: appVersion));

    final closed = Completer<void>();
    _subscription = socket.listen(
      (dynamic message) {
        if (message is String) {
          _unawaited(_handleText(message));
        }
      },
      onError: (Object error) {
        Logger.warning('Channel error: $error', _tag);
      },
      onDone: () {
        if (!closed.isCompleted) closed.complete();
      },
      cancelOnError: false,
    );

    await closed.future;
    final code = socket.closeCode;
    Logger.warning('Channel closed (code ${code ?? '-'})', _tag);
    await _closeSocket();
    return true;
  }

  Future<void> _handleText(String raw) async {
    final frame = DeviceChannelFrame.decode(raw);
    if (frame == null) {
      Logger.warning('Unparseable channel frame', _tag);
      return;
    }
    if (frame.type != 'spot') return;
    if (!_sequence.accept(frame.seq)) {
      Logger.debug(
          'Ignoring spot ${frame.seq}; already at ${_sequence.last}', _tag);
      return;
    }
    final body = frame.data;
    if (body == null) return;
    try {
      await onSpot(body);
    } catch (error) {
      Logger.error('Applying a spot frame failed: $error', _tag);
    }
  }

  void _send(String text) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    try {
      socket.add(text);
    } catch (error) {
      Logger.warning('Channel send failed: $error', _tag);
    }
  }

  Future<void> _waitBeforeRetry() async {
    if (!_running) return;
    final delay = _backoff.next();
    Logger.info('Channel reconnect in ${delay.inSeconds}s', _tag);
    final wait = Completer<void>();
    _reconnectWait = wait;
    _reconnectTimer = Timer(delay, () {
      if (!wait.isCompleted) wait.complete();
    });
    await wait.future;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (identical(_reconnectWait, wait)) _reconnectWait = null;
  }

  void _releaseWait() {
    final wait = _reconnectWait;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  Future<void> _closeSocket() async {
    _setConnected(false);
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    if (!_connection.isClosed) _connection.add(value);
  }
}

void _unawaited(Future<void> future) {
  future.catchError((Object error, StackTrace stackTrace) {
    Logger.error('Unawaited channel future error: $error');
  });
}
