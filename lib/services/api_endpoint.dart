import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../utils/logger.dart';
import 'device_channel/device_channel_protocol.dart';

typedef HostConnect = Future<Duration?> Function(Uri host);
typedef ChannelRouteCheck = Future<bool> Function(String host);

final class HostLatency {
  final String host;
  final int? latencyMs;

  const HostLatency(this.host, this.latencyMs);

  bool get healthy => latencyMs != null;
}

final class ApiEndpoint {
  static const String _tag = 'ApiEndpoint';

  // static const List<String> defaultHosts = ['http://192.168.0.84:9191/api/public'];
  static const List<String> defaultHosts = [
    'https://api.tunio.ai',
    'https://api-eu.tunio.ai',
    'https://api-ru.tunio.ai',
  ];

  static const Duration connectTimeout = Duration(seconds: 4);
  static const Duration routeCheckTimeout = Duration(seconds: 10);
  static const int samplesPerHost = 2;
  static const Duration defaultSampleGap = Duration(milliseconds: 200);
  static const Duration defaultHostGap = Duration(milliseconds: 300);
  static const int switchMarginMs = 40;
  static const int switchMarginPercent = 25;
  static const Duration probeAfterFailure = Duration(seconds: 60);
  static const int failuresBeforeReprobe = 3;

  final List<String> hosts;
  final Duration sampleGap;
  final Duration hostGap;
  final HostConnect _connect;
  final ChannelRouteCheck _servesChannel;
  final DateTime Function() _now;
  final StreamController<String> _changes =
      StreamController<String>.broadcast();

  String _selected;
  int? _selectedLatencyMs;
  int _consecutiveFailures = 0;
  DateTime? _failureProbeNotBefore;
  Future<bool>? _probe;

  ApiEndpoint({
    List<String> hosts = defaultHosts,
    HostConnect? connect,
    ChannelRouteCheck? routeCheck,
    DateTime Function()? now,
    this.sampleGap = defaultSampleGap,
    this.hostGap = defaultHostGap,
  })  : assert(hosts.isNotEmpty),
        hosts = List.unmodifiable(hosts),
        _connect = connect ?? connectOnce,
        _servesChannel = routeCheck ?? checkChannelRoute,
        _now = now ?? DateTime.now,
        _selected = hosts.first;

  String get baseUrl => _selected;

  Uri get channelUrl => deviceChannelUrl(_selected);

  int? get selectedLatencyMs => _selectedLatencyMs;

  bool get isProbing => _probe != null;

  Stream<String> get changes => _changes.stream;

  void reportSuccess() {
    _consecutiveFailures = 0;
  }

  void reportFailure() {
    _consecutiveFailures++;
    if (_consecutiveFailures < failuresBeforeReprobe) return;
    _consecutiveFailures = 0;
    final now = _now();
    final notBefore = _failureProbeNotBefore;
    if (notBefore != null && now.isBefore(notBefore)) return;
    _failureProbeNotBefore = now.add(probeAfterFailure);
    Logger.warning(
        'Repeated failures against $_selected; re-measuring the hosts', _tag);
    unawaited(probe());
  }

  Future<bool> probe() {
    if (hosts.length < 2) return Future<bool>.value(false);
    final running = _probe;
    if (running != null) return running;
    final probe = _run().whenComplete(() {
      _probe = null;
    });
    _probe = probe;
    return probe;
  }

  Future<void> dispose() async {
    await _changes.close();
  }

  Future<bool> _run() async {
    try {
      return await _select();
    } catch (error) {
      Logger.error('Host measurement failed: $error', _tag);
      return false;
    }
  }

  Future<bool> _select() async {
    final current = _selected;
    final results = <HostLatency>[];
    for (final host in hosts) {
      if (results.isNotEmpty && hostGap > Duration.zero) {
        await Future<void>.delayed(hostGap);
      }
      final measured = await _measure(host);
      results.add(measured);
      if (measured.healthy) {
        Logger.info('$host: ${measured.latencyMs} ms', _tag);
      } else {
        Logger.warning('$host: unreachable', _tag);
      }
    }

    final currentResult = results.firstWhere(
      (result) => result.host == current,
      orElse: () => HostLatency(current, null),
    );
    results.sort((a, b) {
      if (a.healthy != b.healthy) return a.healthy ? -1 : 1;
      return (a.latencyMs ?? 0).compareTo(b.latencyMs ?? 0);
    });

    if (!results.first.healthy) {
      Logger.warning(
          'No host answered; staying on $current and letting the retries run',
          _tag);
      return false;
    }
    if (results.first.host == current) {
      _selectedLatencyMs = results.first.latencyMs;
      Logger.info('Staying on $current at ${results.first.latencyMs} ms', _tag);
      return false;
    }

    for (final candidate in results) {
      if (!candidate.healthy || candidate.host == current) break;
      final currentLatency = currentResult.latencyMs;
      if (currentLatency != null) {
        final margin = max(currentLatency - candidate.latencyMs!, 0);
        final farEnough = margin >= switchMarginMs &&
            margin * 100 >= currentLatency * switchMarginPercent;
        if (!farEnough) {
          Logger.info(
              'Keeping $current at $currentLatency ms; ${candidate.host} is '
              '${candidate.latencyMs} ms and not enough better',
              _tag);
          return false;
        }
      }
      if (!await _servesChannel(candidate.host)) continue;
      _selected = candidate.host;
      _selectedLatencyMs = candidate.latencyMs;
      Logger.warning(
          'Switching to ${candidate.host} at ${candidate.latencyMs} ms '
          '(was $current at ${currentResult.latencyMs ?? '-'} ms)',
          _tag);
      if (!_changes.isClosed) _changes.add(candidate.host);
      return true;
    }
    Logger.info('No faster host serves the channel; staying on $current', _tag);
    return false;
  }

  Future<HostLatency> _measure(String host) async {
    final uri = Uri.parse(host);
    int? best;
    for (var sample = 0; sample < samplesPerHost; sample++) {
      if (sample > 0 && sampleGap > Duration.zero) {
        await Future<void>.delayed(sampleGap);
      }
      Duration? elapsed;
      try {
        elapsed = await _connect(uri);
      } catch (_) {
        elapsed = null;
      }
      if (elapsed == null) continue;
      final ms = elapsed.inMilliseconds;
      best = best == null ? ms : min(best, ms);
    }
    return HostLatency(host, best);
  }

  static Future<Duration?> connectOnce(Uri host) async {
    final port = host.hasPort ? host.port : (host.scheme == 'http' ? 80 : 443);
    try {
      final addresses =
          await InternetAddress.lookup(host.host).timeout(connectTimeout);
      if (addresses.isEmpty) return null;
      final address = addresses.firstWhere(
        (candidate) => candidate.type == InternetAddressType.IPv4,
        orElse: () => addresses.first,
      );
      final stopwatch = Stopwatch()..start();
      final socket =
          await Socket.connect(address, port, timeout: connectTimeout);
      stopwatch.stop();
      socket.destroy();
      return stopwatch.elapsed;
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  static Future<bool> checkChannelRoute(String host) async {
    final client = HttpClient()..connectionTimeout = routeCheckTimeout;
    try {
      final request = await client
          .getUrl(Uri.parse('$host/v1/device'))
          .timeout(routeCheckTimeout);
      request.headers
        ..set(HttpHeaders.connectionHeader, 'Upgrade')
        ..set(HttpHeaders.upgradeHeader, 'websocket')
        ..set('Sec-WebSocket-Version', '13')
        ..set('Sec-WebSocket-Key', 'dGhlIHNhbXBsZSBub25jZQ==');
      final response = await request.close().timeout(routeCheckTimeout);
      final status = response.statusCode;
      if (status == HttpStatus.notFound) {
        Logger.warning(
            '$host answers but has no channel route; skipping it', _tag);
        return false;
      }
      return status >= 200 && status < 500;
    } catch (error) {
      Logger.warning('$host: channel route check failed: $error', _tag);
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
