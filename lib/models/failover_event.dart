import 'dart:convert';

enum FailoverEventDirection { failover, restore }

class FailoverEvent {
  final String id;
  final DateTime timestampUtc;
  final FailoverEventDirection direction;
  final String reason;
  final Map<String, dynamic>? extra;
  final bool sent;

  const FailoverEvent({
    required this.id,
    required this.timestampUtc,
    required this.direction,
    required this.reason,
    this.extra,
    this.sent = false,
  });

  FailoverEvent copyWith({
    bool? sent,
    Map<String, dynamic>? extra,
  }) {
    return FailoverEvent(
      id: id,
      timestampUtc: timestampUtc,
      direction: direction,
      reason: reason,
      extra: extra ?? this.extra,
      sent: sent ?? this.sent,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'timestampUtc': timestampUtc.toUtc().toIso8601String(),
      'direction': direction.name,
      'reason': reason,
      'extra': extra,
      'sent': sent,
    };
  }

  static FailoverEvent fromJson(Map<String, dynamic> json) {
    final directionValue = json['direction'] as String? ?? 'failover';
    final direction = FailoverEventDirection.values.firstWhere(
      (value) => value.name == directionValue,
      orElse: () => FailoverEventDirection.failover,
    );

    return FailoverEvent(
      id: json['id'] as String? ?? _generateId(),
      timestampUtc: DateTime.tryParse(json['timestampUtc'] as String? ?? '') ??
          DateTime.now().toUtc(),
      direction: direction,
      reason: json['reason'] as String? ?? 'unknown',
      extra: (json['extra'] as Map<String, dynamic>?) ??
          _decodeExtra(json['extra']),
      sent: json['sent'] as bool? ?? false,
    );
  }

  static Map<String, dynamic>? _decodeExtra(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          return decoded;
        }
      } catch (_) {}
    }
    return null;
  }

  static String _generateId() {
    return DateTime.now().microsecondsSinceEpoch.toString();
  }

  static FailoverEvent create({
    required FailoverEventDirection direction,
    required String reason,
    Map<String, dynamic>? extra,
  }) {
    return FailoverEvent(
      id: _generateId(),
      timestampUtc: DateTime.now().toUtc(),
      direction: direction,
      reason: reason,
      extra: extra,
    );
  }
}
