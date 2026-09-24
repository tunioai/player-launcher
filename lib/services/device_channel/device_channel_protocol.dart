import 'dart:convert';
import 'dart:math';

const int deviceProtocolVersion = 1;

Uri deviceChannelUrl(String baseUrl) {
  final base = Uri.parse(baseUrl);
  final scheme = switch (base.scheme) {
    'https' => 'wss',
    'http' => 'ws',
    final other => other,
  };
  final path = base.path.endsWith('/')
      ? '${base.path}v1/device'
      : '${base.path}/v1/device';
  return base.replace(scheme: scheme, path: path);
}

final class DeviceChannelFrame {
  final int version;
  final String type;
  final int? seq;
  final String? id;
  final Map<String, dynamic>? data;

  const DeviceChannelFrame({
    required this.version,
    required this.type,
    this.seq,
    this.id,
    this.data,
  });

  static DeviceChannelFrame? decode(String raw) {
    final Object? decoded;
    try {
      decoded = json.decode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final type = decoded['t'];
    if (type is! String || type.isEmpty) return null;

    final version = decoded['v'];
    final seq = decoded['seq'];
    final id = decoded['id'];
    final data = decoded['d'];

    return DeviceChannelFrame(
      version: version is int ? version : deviceProtocolVersion,
      type: type,
      seq: seq is int ? seq : (seq is num ? seq.toInt() : null),
      id: id is String ? id : null,
      data: data is Map<String, dynamic> ? data : null,
    );
  }
}

String encodeDeviceFrame(String type,
    {Map<String, dynamic>? data, String? id}) {
  final envelope = <String, dynamic>{
    'v': deviceProtocolVersion,
    't': type,
    if (id != null) 'id': id,
    if (data != null) 'd': data,
  };
  return json.encode(envelope);
}

String helloFrame({
  required String deviceId,
  required String version,
  String kind = 'spot',
  List<String> capabilities = const ['playback', 'volume'],
}) {
  return encodeDeviceFrame('hello', data: {
    'device_id': deviceId,
    'kind': kind,
    'version': version,
    'capabilities': capabilities,
  });
}

final class SpotSequenceGuard {
  int _last = 0;

  int get last => _last;

  void reset() {
    _last = 0;
  }

  bool accept(int? seq) {
    if (seq == null || seq == 0) return true;
    if (seq <= _last) return false;
    _last = seq;
    return true;
  }
}

final class ReconnectBackoff {
  static const Duration defaultBase = Duration(seconds: 3);
  static const Duration defaultCap = Duration(minutes: 5);
  static const int defaultJitterMs = 5000;
  static const int maxShift = 7;

  final Duration base;
  final Duration cap;
  final int jitterMs;
  final Random _random;
  int _failures = 0;

  ReconnectBackoff({
    Random? random,
    this.base = defaultBase,
    this.cap = defaultCap,
    this.jitterMs = defaultJitterMs,
  }) : _random = random ?? Random();

  int get failures => _failures;

  void reset() {
    _failures = 0;
  }

  Duration next() {
    final shift = min(_failures, maxShift);
    final scaledMs = min(base.inMilliseconds << shift, cap.inMilliseconds);
    if (_failures < 255) _failures++;
    final jitter = jitterMs > 0 ? _random.nextInt(jitterMs) : 0;
    return Duration(milliseconds: scaledMs + jitter);
  }
}
