import 'package:flutter/services.dart';

import '../utils/logger.dart';

/// Bridge to the native (Android) screen media cache used by the visualizer:
/// prefetched offline video clips (ExoPlayer SimpleCache) and screen images
/// (webp). Backs the "Screen Cache" card in the local web admin.
class ScreenCacheService {
  static const MethodChannel _channel = MethodChannel('ai.tunio/visualizer');

  /// Returns a JSON-friendly snapshot, or null if unavailable (e.g. non-Android
  /// or the native side failed). Shape:
  /// `{ video: { count, bytes, items: [{name, bytes}] }, images: { count, bytes }, newestMs }`.
  Future<Map<String, dynamic>?> getInfo() async {
    try {
      final result = await _channel.invokeMethod<dynamic>('getScreenCacheInfo');
      if (result is! Map) {
        return null;
      }
      return _normalize(result) as Map<String, dynamic>;
    } catch (e) {
      Logger.warning('ScreenCacheService: getInfo failed: $e');
      return null;
    }
  }

  /// Clears both the video and image caches on the device. Returns false on
  /// failure (the caller keeps the current view).
  Future<bool> clear() async {
    try {
      await _channel.invokeMethod<void>('clearScreenCache');
      return true;
    } catch (e) {
      Logger.error('ScreenCacheService: clear failed: $e');
      return false;
    }
  }

  // MethodChannel hands back Map<Object?, Object?> / List<Object?>; deep-convert
  // to String-keyed maps and plain lists so the result is jsonEncode-friendly.
  static dynamic _normalize(dynamic value) {
    if (value is Map) {
      return value.map<String, dynamic>(
        (key, val) => MapEntry(key.toString(), _normalize(val)),
      );
    }
    if (value is List) {
      return value.map(_normalize).toList();
    }
    return value;
  }
}
