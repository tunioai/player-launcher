import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _apiKeyKey = 'api_key';
  static const String _lastStreamUrlKey = 'last_stream_url';
  static const String _lastVolumeKey = 'last_volume';
  static const String _isAutoStartEnabledKey = 'auto_start_enabled';

  static StorageService? _instance;
  SharedPreferences? _prefs;

  StorageService._();

  static Future<StorageService> getInstance() async {
    _instance ??= StorageService._();
    _instance!._prefs ??= await SharedPreferences.getInstance();
    return _instance!;
  }

  Future<void> saveApiKey(String apiKey) async {
    await _prefs!.setString(_apiKeyKey, apiKey);
  }

  String? getApiKey() {
    return _prefs!.getString(_apiKeyKey);
  }

  Future<void> clearApiKey() async {
    await _prefs!.remove(_apiKeyKey);
  }

  Future<void> saveLastStreamUrl(String url) async {
    await _prefs!.setString(_lastStreamUrlKey, url);
  }

  String? getLastStreamUrl() {
    return _prefs!.getString(_lastStreamUrlKey);
  }

  Future<void> saveLastVolume(double volume) async {
    await _prefs!.setDouble(_lastVolumeKey, volume);
  }

  double getLastVolume() {
    return _prefs!.getDouble(_lastVolumeKey) ?? 1.0;
  }

  Future<void> setAutoStartEnabled(bool enabled) async {
    await _prefs!.setBool(_isAutoStartEnabledKey, enabled);
  }

  bool isAutoStartEnabled() {
    return _prefs!.getBool(_isAutoStartEnabledKey) ?? false;
  }

  Future<void> clear() async {
    await _prefs!.clear();
  }
}
