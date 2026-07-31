import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/logger.dart';

/// Keeps the credentials that must survive shared_preferences.json corruption:
/// the point binding token (PIN), admin key material and the device UUID.
/// shared_preferences rewrites its whole file on every write (including the
/// high-frequency failover history), so a power cut can leave it as garbage.
/// This store lives in a separate tiny file that changes only when a
/// credential changes, is written atomically (temp file + rename) and kept in
/// two copies (main + .bak).
class CredentialStore {
  static const String tokenKey = 'token';
  static const String adminKeyKey = 'admin_key';
  static const String adminKeyHashKey = 'admin_key_hash';
  static const String deviceUuidKey = 'device_uuid';

  static const String _fileName = 'credentials.json';
  static const String _backupFileName = '$_fileName.bak';

  static Future<CredentialStore>? _instance;

  final Map<String, String> _values = <String, String>{};
  Directory? _directory;
  Future<void> _pendingWrite = Future<void>.value();

  CredentialStore._();

  // Memoize the future, not the resolved instance: two callers racing here
  // would otherwise each build a store over the same files, and the loser's
  // in-memory map would silently diverge from what is on disk.
  static Future<CredentialStore> getInstance() => _instance ??= _open();

  static Future<CredentialStore> _open() async {
    final store = CredentialStore._();
    try {
      store._directory = await getApplicationSupportDirectory();
      await store._load();
    } catch (e, stackTrace) {
      Logger.error('CredentialStore: unavailable, using memory only', 'storage',
          e, stackTrace);
    }
    return store;
  }

  @visibleForTesting
  static Future<CredentialStore> openInDirectory(Directory directory) async {
    final store = CredentialStore._();
    store._directory = directory;
    await store._load();
    return store;
  }

  String? get(String key) {
    final value = _values[key];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> set(String key, String? value) {
    if (value == null || value.isEmpty) {
      if (_values.remove(key) == null) return Future<void>.value();
    } else {
      if (_values[key] == value) return Future<void>.value();
      _values[key] = value;
    }
    return _persist();
  }

  Future<void> _load() async {
    final fromMain = await _readMap(_mainFile);
    if (fromMain != null) {
      _values.addAll(fromMain);
      // A backup missing, or left truncated by a build that wrote it in
      // place, would only be discovered once we already needed it. Rebuild it
      // now, while the main copy is still known good.
      if (await _readMap(_backupFile) == null) {
        await _persist();
      }
      return;
    }

    final fromBackup = await _readMap(_backupFile);
    if (fromBackup != null) {
      _values.addAll(fromBackup);
      Logger.warning(
          'CredentialStore: main file unreadable, restored from backup',
          'storage');
      await _persist();
    }
  }

  Future<Map<String, String>?> _readMap(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return <String, String>{
        for (final entry in decoded.entries)
          if (entry.value is String) entry.key: entry.value as String,
      };
    } catch (e) {
      Logger.error(
          'CredentialStore: failed to read ${file.path}: $e', 'storage');
      return null;
    }
  }

  Future<void> _persist() {
    if (_directory == null) return Future<void>.value();
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        final contents = jsonEncode(_values);
        await _writeAtomically(_fileName, contents);
        await _writeAtomically(_backupFileName, contents);
      } catch (e, stackTrace) {
        Logger.error(
            'CredentialStore: failed to persist', 'storage', e, stackTrace);
      }
    });
    return _pendingWrite;
  }

  // Both copies go through temp file + rename. Writing the backup in place
  // would leave it half-written if the power drops mid-write, and nothing
  // would notice until the main file also went bad — exactly the case the
  // second copy exists for.
  Future<void> _writeAtomically(String name, String contents) async {
    final tmp = _fileIn('$name.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(_fileIn(name).path);
  }

  File get _mainFile => _fileIn(_fileName);

  File get _backupFile => _fileIn(_backupFileName);

  File _fileIn(String name) =>
      File('${_directory!.path}${Platform.pathSeparator}$name');
}
