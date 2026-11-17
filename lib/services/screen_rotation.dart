import 'package:flutter/foundation.dart';

import 'storage_service.dart';

/// Clockwise degrees the whole interface is turned by, for a display mounted
/// on its side or upside down.
///
/// Before a PIN is entered only the device knows how it hangs, so the rotation
/// is set locally and remembered. Once linked, a rotation chosen on the Tunio
/// Link in the control panel takes over; a link left at the default keeps a
/// turn the installer made by hand, so it does not snap back the moment the
/// device links. A turn that came from a link is undone by an upright link:
/// moved to another point's PIN, or restarted, the screen follows the link.
class ScreenRotation {
  ScreenRotation._();

  static const List<int> supported = [0, 90, 180, 270];

  static final ValueNotifier<int> degrees = ValueNotifier<int>(0);

  static int? _linkedDegrees;

  static int normalize(int value) => supported.contains(value) ? value : 0;

  static Future<void> restore() async {
    final storage = await StorageService.getInstance();
    degrees.value = normalize(storage.screenRotation());
  }

  static Future<void> rotateClockwise() =>
      _set((degrees.value + 90) % 360, fromLink: false);

  static Future<void> applyLinked(int value) async {
    final linked = normalize(value);
    final previous = _linkedDegrees;
    if (linked == previous) return;
    _linkedDegrees = linked;
    if (previous == null && linked == 0) {
      final storage = await StorageService.getInstance();
      if (!storage.screenRotationFromLink()) return;
    }
    await _set(linked, fromLink: true);
  }

  static Future<void> _set(int value, {required bool fromLink}) async {
    final normalized = normalize(value);
    degrees.value = normalized;
    final storage = await StorageService.getInstance();
    await storage.setScreenRotation(normalized);
    await storage.setScreenRotationFromLink(fromLink);
  }

  @visibleForTesting
  static void forgetLink() => _linkedDegrees = null;
}
