import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/api_endpoint.dart';

const _api = 'https://api.tunio.ai';
const _eu = 'https://api-eu.tunio.ai';
const _ru = 'https://api-ru.tunio.ai';

final class _Fakes {
  final Map<String, List<int?>> latencies;
  final Set<String> withoutRoute;
  final List<String> routeChecks = [];
  final Map<String, int> connects = {};
  DateTime now = DateTime(2026, 9, 24, 12);

  _Fakes({required this.latencies, this.withoutRoute = const {}});

  Future<Duration?> connect(Uri host) async {
    final origin = '${host.scheme}://${host.host}';
    final samples = latencies[origin] ?? const [null];
    final index = connects[origin] ?? 0;
    connects[origin] = index + 1;
    final value = samples[index < samples.length ? index : samples.length - 1];
    return value == null ? null : Duration(milliseconds: value);
  }

  Future<bool> route(String host) async {
    routeChecks.add(host);
    return !withoutRoute.contains(host);
  }

  ApiEndpoint endpoint({List<String> hosts = const [_api, _eu, _ru]}) {
    return ApiEndpoint(
      hosts: hosts,
      connect: connect,
      routeCheck: route,
      now: () => now,
      sampleGap: Duration.zero,
      hostGap: Duration.zero,
    );
  }
}

void main() {
  group('ApiEndpoint selection', () {
    test('starts on the first host before any measurement', () {
      final endpoint = _Fakes(latencies: const {}).endpoint();
      expect(endpoint.baseUrl, _api);
      expect(endpoint.channelUrl.toString(), 'wss://api.tunio.ai/v1/device');
    });

    test('stays when the current host is the fastest', () async {
      final fakes = _Fakes(latencies: const {
        _api: [30],
        _eu: [80],
        _ru: [120],
      });
      final endpoint = fakes.endpoint();

      expect(await endpoint.probe(), isFalse);
      expect(endpoint.baseUrl, _api);
      expect(endpoint.selectedLatencyMs, 30);
      expect(fakes.routeChecks, isEmpty);
    });

    test('switches to a host that is clearly faster and serves the channel',
        () async {
      final fakes = _Fakes(latencies: const {
        _api: [200],
        _eu: [40],
        _ru: [90],
      });
      final endpoint = fakes.endpoint();
      final changes = <String>[];
      endpoint.changes.listen(changes.add);

      expect(await endpoint.probe(), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(endpoint.baseUrl, _eu);
      expect(endpoint.channelUrl.toString(), 'wss://api-eu.tunio.ai/v1/device');
      expect(endpoint.selectedLatencyMs, 40);
      expect(fakes.routeChecks, [_eu]);
      expect(changes, [_eu]);
    });

    test('keeps the current host when the gain is under 40 ms', () async {
      final fakes = _Fakes(latencies: const {
        _api: [60],
        _eu: [25],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      expect(await endpoint.probe(), isFalse);
      expect(endpoint.baseUrl, _api);
      expect(fakes.routeChecks, isEmpty);
    });

    test('keeps the current host when the gain is under a quarter', () async {
      final fakes = _Fakes(latencies: const {
        _api: [400],
        _eu: [340],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      expect(await endpoint.probe(), isFalse);
      expect(endpoint.baseUrl, _api);
      expect(fakes.routeChecks, isEmpty);
    });

    test('the faster one counts of two connects', () async {
      final fakes = _Fakes(latencies: const {
        _api: [300, 120],
        _eu: [500, 30],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      expect(await endpoint.probe(), isTrue);
      expect(fakes.connects, {_api: 2, _eu: 2});
      expect(endpoint.selectedLatencyMs, 30);
    });

    test('a faster host without the channel route is skipped for the next',
        () async {
      final fakes = _Fakes(
        latencies: const {
          _api: [300],
          _eu: [40],
          _ru: [90],
        },
        withoutRoute: const {_eu},
      );
      final endpoint = fakes.endpoint();

      expect(await endpoint.probe(), isTrue);
      expect(endpoint.baseUrl, _ru);
      expect(fakes.routeChecks, [_eu, _ru]);
    });

    test('stays when no faster host serves the channel', () async {
      final fakes = _Fakes(
        latencies: const {
          _api: [300],
          _eu: [40],
        },
        withoutRoute: const {_eu},
      );
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      expect(await endpoint.probe(), isFalse);
      expect(endpoint.baseUrl, _api);
    });

    test('an unreachable current host is left for any healthy one', () async {
      final fakes = _Fakes(latencies: const {
        _api: [null],
        _eu: [900],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      expect(await endpoint.probe(), isTrue);
      expect(endpoint.baseUrl, _eu);
      expect(fakes.routeChecks, [_eu]);
    });

    test('stays when nothing answers', () async {
      final fakes = _Fakes(latencies: const {
        _api: [null],
        _eu: [null],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      expect(await endpoint.probe(), isFalse);
      expect(endpoint.baseUrl, _api);
      expect(fakes.routeChecks, isEmpty);
    });

    test('a single host is never measured', () async {
      final fakes = _Fakes(latencies: const {
        _api: [500],
      });
      final endpoint = fakes.endpoint(hosts: const [_api]);

      expect(await endpoint.probe(), isFalse);
      expect(fakes.connects, isEmpty);
    });

    test('concurrent probes share one measurement', () async {
      final fakes = _Fakes(latencies: const {
        _api: [300],
        _eu: [40],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      final results = await Future.wait([endpoint.probe(), endpoint.probe()]);

      expect(results, [true, true]);
      expect(fakes.connects, {_api: 2, _eu: 2});
    });
  });

  group('ApiEndpoint failure reports', () {
    test('three failures in a row trigger a probe, one or two do not',
        () async {
      final fakes = _Fakes(latencies: const {
        _api: [300],
        _eu: [40],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      endpoint.reportFailure();
      endpoint.reportFailure();
      await Future<void>.delayed(Duration.zero);
      expect(fakes.connects, isEmpty);

      endpoint.reportFailure();
      await _settle(endpoint);
      expect(endpoint.baseUrl, _eu);
    });

    test('a success resets the failure count', () async {
      final fakes = _Fakes(latencies: const {
        _api: [300],
        _eu: [40],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      endpoint.reportFailure();
      endpoint.reportFailure();
      endpoint.reportSuccess();
      endpoint.reportFailure();
      endpoint.reportFailure();
      await Future<void>.delayed(Duration.zero);

      expect(fakes.connects, isEmpty);
      expect(endpoint.baseUrl, _api);
    });

    test('failure-driven probes are at least a minute apart', () async {
      final fakes = _Fakes(latencies: const {
        _api: [300],
        _eu: [40],
      });
      final endpoint = fakes.endpoint(hosts: const [_api, _eu]);

      for (var i = 0; i < 3; i++) {
        endpoint.reportFailure();
      }
      await _settle(endpoint);
      expect(fakes.connects[_api], 2);

      fakes.now = fakes.now.add(const Duration(seconds: 30));
      for (var i = 0; i < 3; i++) {
        endpoint.reportFailure();
      }
      await _settle(endpoint);
      expect(fakes.connects[_api], 2);

      fakes.now = fakes.now.add(const Duration(seconds: 31));
      for (var i = 0; i < 3; i++) {
        endpoint.reportFailure();
      }
      await _settle(endpoint);
      expect(fakes.connects[_api], 4);
    });
  });

  group('ApiEndpoint defaults', () {
    test('times a TCP connect to the port in the URL', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close());
      server.listen((socket) => socket.destroy());

      final elapsed = await ApiEndpoint.connectOnce(
          Uri.parse('http://127.0.0.1:${server.port}'));

      expect(elapsed, isNotNull);
      expect(
          elapsed!.inSeconds, lessThan(ApiEndpoint.connectTimeout.inSeconds));
    });

    test('reports a closed port as unreachable', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      expect(await ApiEndpoint.connectOnce(Uri.parse('http://127.0.0.1:$port')),
          isNull);
    });

    test('the route check sends a websocket handshake and reads the status',
        () async {
      var status = HttpStatus.unauthorized;
      final upgrades = <bool>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        final upgrade =
            request.headers.value(HttpHeaders.upgradeHeader) == 'websocket' &&
                request.headers
                        .value(HttpHeaders.connectionHeader)
                        ?.toLowerCase()
                        .contains('upgrade') ==
                    true &&
                request.headers.value('sec-websocket-key') != null;
        upgrades.add(upgrade);
        request.response.statusCode = upgrade ? status : HttpStatus.badRequest;
        request.response.write('{"message":"Pin is required"}');
        request.response.close();
      });
      final host = 'http://127.0.0.1:${server.port}';

      expect(await ApiEndpoint.checkChannelRoute(host), isTrue);
      status = HttpStatus.notFound;
      expect(await ApiEndpoint.checkChannelRoute(host), isFalse);
      status = HttpStatus.internalServerError;
      expect(await ApiEndpoint.checkChannelRoute(host), isFalse);
      expect(upgrades, [true, true, true]);
    });

    test('the route check fails closed when nothing listens', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      expect(await ApiEndpoint.checkChannelRoute('http://127.0.0.1:$port'),
          isFalse);
    });
  });
}

Future<void> _settle(ApiEndpoint endpoint) async {
  for (var i = 0; i < 50 && endpoint.isProbing; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await Future<void>.delayed(Duration.zero);
}
