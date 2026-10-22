import 'package:flutter/foundation.dart';

import 'storage_service.dart';

/// Clockwise degrees the whole interface is turned by, for a display mounted
/// on its side or upside down.
///
/// Before a PIN is entered only the device knows how it hangs, so the rotation
/// is set locally and remembered. Once linked, a rotation chosen on the Tunio
/// Link in the control panel takes over; a link left at the default keeps the
/// local one, so an installer who turned the screen to type the PIN does not
/// see it snap back the moment the device links.
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

  static Future<void> rotateClockwise() => _set((degrees.value + 90) % 360);

  static Future<void> applyLinked(int value) async {
    final linked = normalize(value);
    final previous = _linkedDegrees;
    if (linked == previous) return;
    _linkedDegrees = linked;
    if (previous == null && linked == 0) return;
    await _set(linked);
  }

  static Future<void> _set(int value) async {
    final normalized = normalize(value);
    degrees.value = normalized;
    final storage = await StorageService.getInstance();
    await storage.setScreenRotation(normalized);
  }
}
