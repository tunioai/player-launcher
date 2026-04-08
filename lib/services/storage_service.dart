import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/failover_event.dart';
import '../utils/logger.dart';

class StorageService {
  static const String _tokenKey = 'token';
  static const String _adminKeyKey = 'admin_key';
  static const String _adminKeyHashKey = 'admin_key_hash';
  static const String _lastVolumeKey = 'last_volume';
  static const String _isAutoStartEnabledKey = 'auto_start_enabled';
  static const String _isDarkModeEnabledKey = 'dark_mode_enabled';
  static const String _failoverEventsKey = 'failover_events';
  static const String _failoverTrackLastPlayedKey =
      'failover_track_last_played_v1';
  static const String _serviceSuspendedKey = 'service_suspended';
  static const String _serviceSuspendedWarningUrlKey =
      'service_suspended_warning_url';
  static const String _cachedWarningMessagePathKey =
      'cached_warning_message_path';
  static const int _maxFailoverEvents = 200;
  // Keep some slack for forward-compat, but never let this grow without bound.
  static const int _maxFailoverTrackHistoryEntries = 250;

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

  // Admin key methods
  Future<void> saveAdminKey(String key) async {
    await _prefs!.setString(_adminKeyKey, key);
    Logger.debug('🔐 StorageService: Admin key saved', 'StorageService');
  }

  String? getAdminKey() {
    final key = _prefs!.getString(_adminKeyKey);
    Logger.debug(
        '🔐 StorageService: Admin key loaded: ${key != null && key.isNotEmpty ? 'set' : 'NULL'}',
        'StorageService');
    return key;
  }

  Future<void> clearAdminKey() async {
    await _prefs!.remove(_adminKeyKey);
    Logger.debug('🔐 StorageService: Admin key cleared', 'StorageService');
  }

  Future<void> saveAdminKeyHash(String hash) async {
    await _prefs!.setString(_adminKeyHashKey, hash);
    Logger.debug('🔐 StorageService: Admin key hash saved', 'StorageService');
  }

  String? getAdminKeyHash() {
    final hash = _prefs!.getString(_adminKeyHashKey);
    Logger.debug(
        '🔐 StorageService: Admin key hash loaded: ${hash != null && hash.isNotEmpty ? 'set' : 'NULL'}',
        'StorageService');
    return hash;
  }

  Future<void> clearAdminKeyHash() async {
    await _prefs!.remove(_adminKeyHashKey);
    Logger.debug('🔐 StorageService: Admin key hash cleared', 'StorageService');
  }

  // Persist the last known failover/music volume so we can reuse it when
  // entering failover without fresh config.
  Future<void> saveLastVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    await _prefs!.setDouble(_lastVolumeKey, clamped);
  }

  double getLastVolume() {
    final stored = _prefs!.getDouble(_lastVolumeKey);
    if (stored == null) return 1.0;
    return stored.clamp(0.0, 1.0);
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

  Future<void> saveServiceSuspensionWarningUrl(String warningUrl) async {
    final normalized = warningUrl.trim();
    if (normalized.isEmpty) return;

    await _prefs!.setBool(_serviceSuspendedKey, true);
    await _prefs!.setString(_serviceSuspendedWarningUrlKey, normalized);
    Logger.info(
        '🚫 StorageService: Service suspension enabled with warning URL',
        'StorageService');
  }

  Future<void> clearServiceSuspension() async {
    await _prefs!.setBool(_serviceSuspendedKey, false);
    await _prefs!.remove(_serviceSuspendedWarningUrlKey);
    Logger.info(
        '🚫 StorageService: Service suspension cleared', 'StorageService');
  }

  bool isServiceSuspended() {
    return _prefs!.getBool(_serviceSuspendedKey) ?? false;
  }

  String? getServiceSuspensionWarningUrl() {
    final warningUrl = _prefs!.getString(_serviceSuspendedWarningUrlKey);
    if (warningUrl == null || warningUrl.trim().isEmpty) {
      return null;
    }
    return warningUrl.trim();
  }

  Future<void> saveCachedWarningMessagePath(String filePath) async {
    final normalized = filePath.trim();
    if (normalized.isEmpty) return;
    await _prefs!.setString(_cachedWarningMessagePathKey, normalized);
  }

  String? getCachedWarningMessagePath() {
    final path = _prefs!.getString(_cachedWarningMessagePathKey);
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    return path.trim();
  }

  Future<void> clearCachedWarningMessagePath() async {
    await _prefs!.remove(_cachedWarningMessagePathKey);
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

  // Failover track playback history (uuid -> lastPlayedAtMillis)
  Map<String, int> getFailoverTrackLastPlayed() {
    final raw = _prefs!.getString(_failoverTrackLastPlayedKey);
    if (raw == null || raw.isEmpty) return <String, int>{};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};

      final out = <String, int>{};
      for (final entry in decoded.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String) continue;
        if (value is int) {
          out[key] = value;
          continue;
        }
        if (value is String) {
          final parsed = int.tryParse(value);
          if (parsed != null) {
            out[key] = parsed;
          }
        }
      }
      return out;
    } catch (e) {
      Logger.error(
          'Failed to decode failover track history: $e', 'StorageService');
      return <String, int>{};
    }
  }

  Future<void> markFailoverTrackPlayed(String uuid,
      {DateTime? playedAt}) async {
    if (uuid.isEmpty) return;

    final history = getFailoverTrackLastPlayed();
    history[uuid] = (playedAt ?? DateTime.now()).millisecondsSinceEpoch;

    // Trim the oldest entries if we somehow exceeded bounds.
    if (history.length > _maxFailoverTrackHistoryEntries) {
      final entries = history.entries.toList(growable: false);
      entries.sort((a, b) => b.value.compareTo(a.value)); // newest first
      history
        ..clear()
        ..addEntries(entries.take(_maxFailoverTrackHistoryEntries));
    }

    await _prefs!.setString(_failoverTrackLastPlayedKey, jsonEncode(history));
  }

  Future<void> pruneFailoverTrackHistory(Set<String> validUuids) async {
    if (validUuids.isEmpty) {
      await clearFailoverTrackHistory();
      return;
    }

    final history = getFailoverTrackLastPlayed();
    var changed = false;
    final keys = history.keys.toList(growable: false);
    for (final key in keys) {
      if (!validUuids.contains(key)) {
        history.remove(key);
        changed = true;
      }
    }
    if (!changed) return;

    await _prefs!.setString(_failoverTrackLastPlayedKey, jsonEncode(history));
  }

  Future<void> clearFailoverTrackHistory() async {
    await _prefs!.remove(_failoverTrackLastPlayedKey);
  }
}
