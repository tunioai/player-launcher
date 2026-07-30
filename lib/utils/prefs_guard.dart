import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'logger.dart';

/// Single entry point for SharedPreferences. On Windows/Linux the prefs live
/// in a JSON file that is rewritten in full on every write; a power cut can
/// leave unparseable garbage, and the resulting FormatException used to kill
/// the whole startup (blank window). Deleting the corrupted file and starting
/// with fresh prefs only loses cosmetics — the credentials survive in
/// CredentialStore.
class PrefsGuard {
  static const String _fileName = 'shared_preferences.json';

  /// Only Windows and Linux keep prefs in a JSON file we own and can delete.
  /// Android stores them as native XML (the platform keeps its own .bak and
  /// recovers on its own) and macOS uses NSUserDefaults, so there is nothing
  /// here to repair on those platforms.
  @visibleForTesting
  static bool repairable = Platform.isWindows || Platform.isLinux;

  /// Seam for tests: the underlying loader, so the corrupted-prefs path can be
  /// exercised without a real half-written file.
  @visibleForTesting
  static Future<SharedPreferences> Function() loader =
      SharedPreferences.getInstance;

  static Future<SharedPreferences> getInstance() async {
    try {
      return await loader();
    } on FormatException catch (e, stackTrace) {
      if (!repairable) {
        // Nothing we can delete here — surface it loudly instead of retrying
        // the same failing read and pretending we handled it.
        Logger.error(
            'shared_preferences is unreadable and cannot be repaired on '
            '${Platform.operatingSystem}',
            'storage',
            e,
            stackTrace);
        rethrow;
      }
      Logger.error('shared_preferences file is corrupted, resetting it',
          'storage', e, stackTrace);
      await _deleteCorruptedFile();
      return loader();
    }
  }

  static Future<void> _deleteCorruptedFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e, stackTrace) {
      Logger.error('Failed to delete corrupted shared_preferences file',
          'storage', e, stackTrace);
    }
  }
}
