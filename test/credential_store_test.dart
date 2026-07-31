import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/credential_store.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('credential_store_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File mainFile() => File('${tempDir.path}/credentials.json');
  File backupFile() => File('${tempDir.path}/credentials.json.bak');

  test('persists values and reloads them from disk', () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    await store.set(CredentialStore.tokenKey, '123456');
    await store.set(CredentialStore.deviceUuidKey, 'uuid-1');

    final reloaded = await CredentialStore.openInDirectory(tempDir);
    expect(reloaded.get(CredentialStore.tokenKey), '123456');
    expect(reloaded.get(CredentialStore.deviceUuidKey), 'uuid-1');
    expect(mainFile().existsSync(), isTrue);
    expect(backupFile().existsSync(), isTrue);
  });

  test('restores from backup when main file is corrupted and heals it',
      () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    await store.set(CredentialStore.tokenKey, '123456');

    mainFile().writeAsStringSync('\x00\x00garbage');

    final reloaded = await CredentialStore.openInDirectory(tempDir);
    expect(reloaded.get(CredentialStore.tokenKey), '123456');

    final healed = jsonDecode(mainFile().readAsStringSync());
    expect(healed[CredentialStore.tokenKey], '123456');
  });

  test('starts empty and stays usable when both copies are corrupted',
      () async {
    mainFile().writeAsStringSync('garbage');
    backupFile().writeAsStringSync('garbage');

    final store = await CredentialStore.openInDirectory(tempDir);
    expect(store.get(CredentialStore.tokenKey), isNull);

    await store.set(CredentialStore.tokenKey, '654321');
    final reloaded = await CredentialStore.openInDirectory(tempDir);
    expect(reloaded.get(CredentialStore.tokenKey), '654321');
  });

  test('setting null removes the value from both copies', () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    await store.set(CredentialStore.tokenKey, '123456');
    await store.set(CredentialStore.tokenKey, null);

    expect(store.get(CredentialStore.tokenKey), isNull);
    expect(jsonDecode(mainFile().readAsStringSync()), isEmpty);
    expect(jsonDecode(backupFile().readAsStringSync()), isEmpty);
  });

  test('treats empty values as absent', () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    await store.set(CredentialStore.tokenKey, '');
    expect(store.get(CredentialStore.tokenKey), isNull);
    expect(mainFile().existsSync(), isFalse);
  });

  // Durability invariant: a power cut can only ever interrupt a write to a
  // .tmp file, so whatever is left at credentials.json / .bak always parses.
  test('leaves both copies parseable after every write', () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    for (var i = 0; i < 5; i++) {
      await store.set(CredentialStore.tokenKey, '00000$i');
      await store.set(CredentialStore.adminKeyKey, 'key-$i');

      expect(jsonDecode(mainFile().readAsStringSync()),
          containsPair(CredentialStore.tokenKey, '00000$i'));
      expect(jsonDecode(backupFile().readAsStringSync()),
          containsPair(CredentialStore.tokenKey, '00000$i'));
    }

    final leftovers = tempDir
        .listSync()
        .map((e) => e.path.split(Platform.pathSeparator).last)
        .where((name) => name.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

  test('rebuilds an unreadable backup on load, before it is needed', () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    await store.set(CredentialStore.tokenKey, '123456');

    // What a build that wrote the backup in place could leave behind after a
    // power cut: main still good, backup half-written.
    backupFile().writeAsStringSync('{"tok');

    // Next launch heals it...
    await CredentialStore.openInDirectory(tempDir);
    expect(jsonDecode(backupFile().readAsStringSync()),
        containsPair(CredentialStore.tokenKey, '123456'));

    // ...so the PIN is still recoverable when the main copy later goes bad.
    mainFile().writeAsStringSync('\x00\x00');
    final reloaded = await CredentialStore.openInDirectory(tempDir);
    expect(reloaded.get(CredentialStore.tokenKey), '123456');
  });

  test('recreates a missing backup on load', () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    await store.set(CredentialStore.tokenKey, '123456');
    backupFile().deleteSync();

    await CredentialStore.openInDirectory(tempDir);
    expect(jsonDecode(backupFile().readAsStringSync()),
        containsPair(CredentialStore.tokenKey, '123456'));
  });

  test('serializes concurrent writes, last one wins on disk', () async {
    final store = await CredentialStore.openInDirectory(tempDir);
    await Future.wait([
      store.set(CredentialStore.tokenKey, '111111'),
      store.set(CredentialStore.adminKeyKey, 'admin'),
      store.set(CredentialStore.tokenKey, '222222'),
    ]);

    final reloaded = await CredentialStore.openInDirectory(tempDir);
    expect(reloaded.get(CredentialStore.tokenKey), '222222');
    expect(reloaded.get(CredentialStore.adminKeyKey), 'admin');
  });
}
