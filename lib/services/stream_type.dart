import 'package:flutter/foundation.dart';

import '../utils/logger.dart';
import 'storage_service.dart';

/// Which of the two live streams a point plays: the HLS playlist or the plain
/// AAC (Icecast) stream. Both come with every config.
enum StreamType {
  auto,
  hls,
  aac;

  static StreamType parse(Object? raw) => switch ('$raw'.trim().toLowerCase()) {
        'hls' => StreamType.hls,
        'aac' => StreamType.aac,
        _ => StreamType.auto,
      };
}

/// The stream the point plays, and why.
///
/// Auto plays HLS and moves to AAC, until the app restarts, once HLS proves
/// unusable on this point: loads that hang twice in a row, or three real stalls
/// within fifteen minutes. A point behind a proxy that starves the native
/// player's HLS fetches then plays the AAC stream instead of living in the
/// cache. A plain outage does not count: it fails fast, and AAC is no better.
///
/// The choice is made on the device and remembered; a type chosen for the
/// point in the control panel takes over when it changes, and a panel left at
/// auto keeps the device's own choice, as with the screen rotation.
class StreamTypePreference {
  StreamTypePreference._();

  static const int hangsBeforeFallback = 2;
  static const int stallsBeforeFallback = 3;
  static const Duration stallWindow = Duration(minutes: 15);

  static final ValueNotifier<StreamType> selected =
      ValueNotifier<StreamType>(StreamType.auto);

  /// Why auto left HLS, or null while it has not.
  static final ValueNotifier<String?> fallbackReason =
      ValueNotifier<String?>(null);

  static StreamType? _linked;
  static int _consecutiveHangs = 0;
  static final List<DateTime> _stalls = [];

  /// Called when auto gives up on HLS, with the reason.
  static void Function(String reason)? onFallback;

  static bool get usingFallback =>
      selected.value == StreamType.auto && fallbackReason.value != null;

  static Future<void> restore() async {
    final storage = await StorageService.getInstance();
    selected.value = StreamType.parse(storage.streamType());
  }

  static Future<void> choose(StreamType type) async {
    if (selected.value == type) return;
    Logger.warning('🎚️ STREAM TYPE: ${selected.value.name} -> ${type.name}');
    selected.value = type;
    final storage = await StorageService.getInstance();
    await storage.setStreamType(type.name);
  }

  static Future<void> applyLinked(StreamType type) async {
    final previous = _linked;
    if (type == previous) return;
    _linked = type;
    if (previous == null && type == StreamType.auto) return;
    await choose(type);
  }

  /// The URL to play out of the two the backend sends.
  static String resolve({String? hlsUrl, String? aacUrl}) {
    final hls = hlsUrl?.trim() ?? '';
    final aac = aacUrl?.trim() ?? '';
    final wantsAac = switch (selected.value) {
      StreamType.aac => true,
      StreamType.hls => false,
      StreamType.auto => fallbackReason.value != null,
    };
    if (wantsAac && aac.isNotEmpty) return aac;
    return hls.isNotEmpty ? hls : aac;
  }

  static void reportHlsLoadHang() {
    _consecutiveHangs++;
    if (_consecutiveHangs >= hangsBeforeFallback) {
      _fallBack('HLS failed to load $_consecutiveHangs times in a row');
    }
  }

  static void reportHlsLoaded() {
    _consecutiveHangs = 0;
  }

  static void reportHlsStall({DateTime? at}) {
    final now = at ?? DateTime.now();
    _stalls
      ..add(now)
      ..removeWhere((t) => now.difference(t) > stallWindow);
    if (_stalls.length >= stallsBeforeFallback) {
      _fallBack('HLS stalled ${_stalls.length} times in '
          '${stallWindow.inMinutes} minutes');
    }
  }

  static void _fallBack(String reason) {
    if (selected.value != StreamType.auto || fallbackReason.value != null) {
      return;
    }
    Logger.warning('🎚️ STREAM TYPE: auto falls back to AAC - $reason');
    fallbackReason.value = reason;
    onFallback?.call(reason);
  }

  @visibleForTesting
  static void resetForTest() {
    selected.value = StreamType.auto;
    fallbackReason.value = null;
    _linked = null;
    _consecutiveHangs = 0;
    _stalls.clear();
    onFallback = null;
  }
}
