import 'dart:io';

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
  static Future<SharedPreferences> getInstance() async {
    try {
      return await SharedPreferences.getInstance();
    } on FormatException catch (e, stackTrace) {
      Logger.error('shared_preferences file is corrupted, resetting it',
          'storage', e, stackTrace);
      await _deleteCorruptedFile();
      return SharedPreferences.getInstance();
    }
  }

  static Future<void> _deleteCorruptedFile() async {
    if (!Platform.isWindows && !Platform.isLinux) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file =
          File('${dir.path}${Platform.pathSeparator}shared_preferences.json');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e, stackTrace) {
      Logger.error('Failed to delete corrupted shared_preferences file',
          'storage', e, stackTrace);
    }
  }
}
