import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/device_channel/device_channel_client.dart';
import 'package:tunio_radio_player/services/device_channel/device_channel_protocol.dart';

final class _FakeDeviceServer {
  late final HttpServer _server;
  final List<HttpHeaders> handshakes = [];
  final StreamController<WebSocket> _accepted = StreamController<WebSocket>();

  Stream<WebSocket> get accepted => _accepted.stream;
  Uri get url => Uri(
      scheme: 'ws', host: '127.0.0.1', port: _server.port, path: '/v1/device');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      handshakes.add(request.headers);
      final socket = await WebSocketTransformer.upgrade(request);
      _accepted.add(socket);
    });
  }

  Future<void> stop() async {
    await _server.close(force: true);
    unawaited(_accepted.close());
  }
}

Stream<dynamic> _drained(WebSocket socket) {
  final frames = StreamController<dynamic>();
  socket.listen(frames.add, onError: frames.addError, onDone: frames.close);
  return frames.stream;
}

String _spot(int seq, String title) => json.encode({
      'v': 1,
      't': 'spot',
      'seq': seq,
      'd': {
        'success': true,
        'stream': {'title': title},
        'config': {'offline_mode': false},
      },
    });

void main() {
  late _FakeDeviceServer server;
  late List<Map<String, dynamic>> applied;
  late DeviceChannelClient client;

  setUp(() async {
    server = _FakeDeviceServer();
    await server.start();
    applied = [];
    client = DeviceChannelClient(
      url: server.url,
      pin: '123456',
      deviceId: 'test-device',
      appVersion: '0.0.0+1',
      extraHeaders: const {'X-Platform': 'test'},
      onSpot: (body) async => applied.add(body),
      backoff: ReconnectBackoff(
        random: Random(1),
        base: const Duration(milliseconds: 20),
        cap: const Duration(milliseconds: 40),
        jitterMs: 0,
      ),
    );
  });

  tearDown(() async {
    await client.dispose();
    await server.stop();
  });

  test('connects with the PIN as a bearer header and says hello', () async {
    final socketFuture = server.accepted.first;
    client.start();
    final socket = await socketFuture;

    expect(server.handshakes.single.value('authorization'), 'Bearer 123456');
    expect(server.handshakes.single.value('x-platform'), 'test');

    final hello = DeviceChannelFrame.decode(await socket.first as String)!;
    expect(hello.type, 'hello');
    expect(hello.data?['device_id'], 'test-device');
    expect(hello.data?['kind'], 'spot');
  });

  test('applies spot frames in order and drops a stale one', () async {
    final socketFuture = server.accepted.first;
    client.start();
    final socket = await socketFuture;
    await socket.first;

    socket.add(_spot(1, 'first'));
    socket.add(_spot(3, 'third'));
    socket.add(_spot(2, 'stale'));
    socket.add(_spot(4, 'fourth'));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
        applied.map((b) => b['stream']['title']), ['first', 'third', 'fourth']);
  });

  test('reconnects after the server hangs up and accepts seq 1 again',
      () async {
    final sockets = StreamIterator(server.accepted);
    client.start();

    await sockets.moveNext();
    final first = sockets.current;
    final firstFrames = StreamIterator<dynamic>(_drained(first));
    await firstFrames.moveNext();
    first.add(_spot(5, 'before'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.isConnected, isTrue);

    await first.close();
    await sockets.moveNext();
    final second = sockets.current;
    final secondFrames = StreamIterator<dynamic>(_drained(second));
    await secondFrames.moveNext();
    expect(server.handshakes.length, 2);

    second.add(_spot(1, 'after'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(applied.map((b) => b['stream']['title']), ['before', 'after']);
    await sockets.cancel();
  });

  test('stop keeps the channel down', () async {
    client.start();
    await server.accepted.first;
    await client.stop();
    expect(client.isConnected, isFalse);
    expect(client.isRunning, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(server.handshakes.length, 1);
  });
}
