import 'package:shared_preferences/shared_preferences.dart';
import '../utils/logger.dart';

class StorageService {
  static const String _tokenKey = 'token';
  static const String _lastVolumeKey = 'last_volume';
  static const String _isAutoStartEnabledKey = 'auto_start_enabled';
  static const String _isDarkModeEnabledKey = 'dark_mode_enabled';

  static StorageService? _instance;
  SharedPreferences? _prefs;

  StorageService._();

  static Future<StorageService> getInstance() async {
    _instance ??= StorageService._();
    _instance!._prefs ??= await SharedPreferences.getInstance();
    return _instance!;
  }

  // Token methods / Pincode
  Future<void> saveToken(String token) async {
    await _prefs!.setString(_tokenKey, token);
    Logger.debug('🔑 StorageService: Token saved: ${token.substring(0, 2)}****',
        'StorageService');
  }

  String? getToken() {
    final token = _prefs!.getString(_tokenKey);
    Logger.debug(
        '🔑 StorageService: Token loaded: ${token != null ? '${token.substring(0, 2)}****' : 'NULL'}',
        'StorageService');
    return token;
  }

  Future<void> clearToken() async {
    await _prefs!.remove(_tokenKey);
    Logger.debug('🔑 StorageService: Token cleared', 'StorageService');
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

  // Dark mode methods
  Future<void> setDarkModeEnabled(bool enabled) async {
    await _prefs!.setBool(_isDarkModeEnabledKey, enabled);
  }

  bool? isDarkModeEnabled() {
    return _prefs!.getBool(_isDarkModeEnabledKey);
  }

  Future<void> clearDarkModePreference() async {
    await _prefs!.remove(_isDarkModeEnabledKey);
  }

  Future<void> clear() async {
    await _prefs!.clear();
  }
}
