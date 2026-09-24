import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/device_channel/device_channel_protocol.dart';

void main() {
  group('deviceChannelUrl', () {
    test('upgrades https to wss and appends /v1/device', () {
      expect(deviceChannelUrl('https://api.tunio.ai').toString(),
          'wss://api.tunio.ai/v1/device');
    });

    test('keeps a public prefix and upgrades plain http for dev', () {
      expect(deviceChannelUrl('http://192.168.0.84:9191/api/public').toString(),
          'ws://192.168.0.84:9191/api/public/v1/device');
    });
  });

  group('DeviceChannelFrame.decode', () {
    test('reads a spot envelope', () {
      final frame = DeviceChannelFrame.decode(
          '{"v":1,"t":"spot","seq":7,"d":{"success":true,"stream":{}}}');
      expect(frame, isNotNull);
      expect(frame!.type, 'spot');
      expect(frame.seq, 7);
      expect(frame.data?['success'], true);
    });

    test('rejects frames without a type or that are not objects', () {
      expect(DeviceChannelFrame.decode('{"v":1}'), isNull);
      expect(DeviceChannelFrame.decode('[]'), isNull);
      expect(DeviceChannelFrame.decode('not json'), isNull);
    });

    test('keeps a frame whose payload is not an object', () {
      final frame = DeviceChannelFrame.decode('{"t":"welcome","d":"x"}');
      expect(frame, isNotNull);
      expect(frame!.data, isNull);
    });
  });

  group('helloFrame', () {
    test('carries identity, kind, version and capabilities', () {
      final raw = helloFrame(deviceId: 'abc', version: '1.9.0+32');
      final frame = DeviceChannelFrame.decode(raw)!;
      expect(frame.type, 'hello');
      expect(frame.data?['device_id'], 'abc');
      expect(frame.data?['kind'], 'spot');
      expect(frame.data?['version'], '1.9.0+32');
      expect(frame.data?['capabilities'], ['playback', 'volume']);
    });
  });

  group('SpotSequenceGuard', () {
    test('applies increasing sequences and drops stale ones', () {
      final guard = SpotSequenceGuard();
      expect(guard.accept(1), isTrue);
      expect(guard.accept(3), isTrue);
      expect(guard.accept(2), isFalse);
      expect(guard.accept(3), isFalse);
      expect(guard.accept(4), isTrue);
    });

    test('accepts unnumbered frames without moving the watermark', () {
      final guard = SpotSequenceGuard();
      expect(guard.accept(5), isTrue);
      expect(guard.accept(null), isTrue);
      expect(guard.accept(0), isTrue);
      expect(guard.last, 5);
    });

    test('reset lets the first frame of a new connection through', () {
      final guard = SpotSequenceGuard();
      guard.accept(9);
      guard.reset();
      expect(guard.accept(1), isTrue);
    });
  });

  group('ReconnectBackoff', () {
    test('doubles from 3 s, caps at 5 min, resets on success', () {
      final backoff = ReconnectBackoff(random: Random(0));
      final delays = List.generate(10, (_) => backoff.next());
      Duration strip(Duration d) =>
          Duration(milliseconds: d.inMilliseconds ~/ 1000 * 1000);

      expect(strip(delays[0]).inSeconds, inInclusiveRange(3, 8));
      expect(strip(delays[1]).inSeconds, inInclusiveRange(6, 11));
      expect(strip(delays[2]).inSeconds, inInclusiveRange(12, 17));
      expect(
          delays[9].inMilliseconds,
          lessThanOrEqualTo(ReconnectBackoff.defaultCap.inMilliseconds +
              ReconnectBackoff.defaultJitterMs));
      expect(delays[9].inMilliseconds,
          greaterThanOrEqualTo(ReconnectBackoff.defaultCap.inMilliseconds));

      backoff.reset();
      expect(backoff.failures, 0);
      expect(backoff.next().inSeconds, inInclusiveRange(3, 8));
    });
  });
}
