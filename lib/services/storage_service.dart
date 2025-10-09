import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/failover_event.dart';
import '../utils/logger.dart';

class StorageService {
  static const String _tokenKey = 'token';
  static const String _lastVolumeKey = 'last_volume';
  static const String _isAutoStartEnabledKey = 'auto_start_enabled';
  static const String _isDarkModeEnabledKey = 'dark_mode_enabled';
  static const String _failoverEventsKey = 'failover_events';
  static const int _maxFailoverEvents = 200;

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

  List<FailoverEvent> getFailoverEvents({bool includeSent = true}) {
    final raw = _prefs!.getString(_failoverEventsKey);
    if (raw == null || raw.isEmpty) {
      return <FailoverEvent>[];
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <FailoverEvent>[];

      final events = decoded
          .whereType<Map<String, dynamic>>()
          .map(FailoverEvent.fromJson)
          .toList(growable: true);

      if (events.length > _maxFailoverEvents) {
        return events.sublist(events.length - _maxFailoverEvents);
      }

      if (includeSent) {
        return events;
      }

      return events.where((event) => !event.sent).toList(growable: true);
    } catch (e) {
      Logger.error('Failed to decode failover events: $e', 'StorageService');
      return <FailoverEvent>[];
    }
  }

  Future<void> appendFailoverEvent(FailoverEvent event) async {
    final events = getFailoverEvents();
    events.add(event);

    while (events.length > _maxFailoverEvents) {
      events.removeAt(0);
    }

    await _saveFailoverEvents(events);
  }

  Future<void> markFailoverEventsAsSent(List<String> ids) async {
    if (ids.isEmpty) return;

    final events = getFailoverEvents();
    var updated = false;

    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      if (ids.contains(event.id) && !event.sent) {
        events[i] = event.copyWith(sent: true);
        updated = true;
      }
    }

    if (updated) {
      await _saveFailoverEvents(events);
    }
  }

  Future<void> clearSentFailoverEvents() async {
    final events = getFailoverEvents();
    final filtered = events.where((event) => !event.sent).toList();
    if (filtered.length == events.length) return;
    await _saveFailoverEvents(filtered);
  }

  Future<void> _saveFailoverEvents(List<FailoverEvent> events) async {
    final encoded = jsonEncode(events.map((event) => event.toJson()).toList());
    await _prefs!.setString(_failoverEventsKey, encoded);
  }
}
