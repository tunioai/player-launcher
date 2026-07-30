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

  static CredentialStore? _instance;

  final Map<String, String> _values = <String, String>{};
  Directory? _directory;
  Future<void> _pendingWrite = Future<void>.value();

  CredentialStore._();

  static Future<CredentialStore> getInstance() async {
    if (_instance != null) return _instance!;
    final store = CredentialStore._();
    try {
      store._directory = await getApplicationSupportDirectory();
      await store._load();
    } catch (e, stackTrace) {
      Logger.error('CredentialStore: unavailable, using memory only', 'storage',
          e, stackTrace);
    }
    _instance = store;
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
        final tmp = _fileIn('$_fileName.tmp');
        await tmp.writeAsString(contents, flush: true);
        await tmp.rename(_mainFile.path);
        await _backupFile.writeAsString(contents, flush: true);
      } catch (e, stackTrace) {
        Logger.error(
            'CredentialStore: failed to persist', 'storage', e, stackTrace);
      }
    });
    return _pendingWrite;
  }

  File get _mainFile => _fileIn(_fileName);

  File get _backupFile => _fileIn('$_fileName.bak');

  File _fileIn(String name) =>
      File('${_directory!.path}${Platform.pathSeparator}$name');
}
