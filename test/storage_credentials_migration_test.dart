import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunio_radio_player/services/credential_store.dart';
import 'package:tunio_radio_player/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Both services are process-wide singletons, so this is one linear scenario
  // rather than several independent tests: an install that predates
  // CredentialStore, upgraded, then hit by the prefs corruption.
  test('migrates prefs credentials and survives a prefs reset', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'token': '123456',
      'admin_key': 'admin-key',
      'admin_key_hash': 'admin-hash',
    });

    final storage = await StorageService.getInstance();

    // Upgrade copied the credentials out of prefs...
    final credentials = await CredentialStore.getInstance();
    expect(credentials.get(CredentialStore.tokenKey), '123456');
    expect(credentials.get(CredentialStore.adminKeyKey), 'admin-key');
    expect(credentials.get(CredentialStore.adminKeyHashKey), 'admin-hash');

    // ...so wiping prefs (what PrefsGuard does to a corrupted file) no longer
    // takes the point binding with it.
    await (await SharedPreferences.getInstance()).clear();

    expect(storage.getToken(), '123456');
    expect(storage.getAdminKey(), 'admin-key');
    expect(storage.getAdminKeyHash(), 'admin-hash');
  });
}
