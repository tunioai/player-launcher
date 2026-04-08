import '../utils/logger.dart';

/// Holds application-wide runtime flags that can be toggled from backend/config.
class SystemState {
  SystemState._();

  static final SystemState instance = SystemState._();

  bool _offlineMode = false;
  bool _offlineOverrideActive = false;
  bool _serviceSuspended = false;
  String? _warningMessageUrl;

  bool get offlineMode => _offlineMode;
  bool get offlineOverrideActive => _offlineOverrideActive;
  bool get serviceSuspended => _serviceSuspended;
  String? get warningMessageUrl => _warningMessageUrl;

  /// Updates offline mode only if the value changes. Returns true when changed.
  bool setOfflineMode(bool value) {
    if (_offlineMode == value) {
      return false;
    }

    _offlineMode = value;
    Logger.info(
        '🛰️ SYSTEM_STATE: Offline mode ${value ? 'ENABLED' : 'DISABLED'}');
    return true;
  }

  /// Overrides offline mode locally for the current session only.
  /// Backend updates are ignored while override is active.
  bool setOfflineModeLocalOverride(bool value) {
    _offlineOverrideActive = true;
    final changed = setOfflineMode(value);
    if (changed) {
      Logger.info(
          '🛰️ SYSTEM_STATE: Offline mode locally overridden ${value ? 'ENABLED' : 'DISABLED'}');
    } else {
      Logger.info(
          '🛰️ SYSTEM_STATE: Offline mode local override set (no change)');
    }
    return changed;
  }

  /// Clears local override so backend config can apply again.
  void clearOfflineOverride() {
    if (_offlineOverrideActive) {
      _offlineOverrideActive = false;
      Logger.info('🛰️ SYSTEM_STATE: Offline mode local override cleared');
    }
  }

  /// Applies a nullable offline mode value typically coming from backend config.
  bool syncOfflineMode(bool? value) {
    if (value == null) {
      return false;
    }
    if (_offlineOverrideActive) {
      return false;
    }
    return setOfflineMode(value);
  }

  bool setServiceSuspended(bool value, {String? warningMessageUrl}) {
    final normalizedUrl = warningMessageUrl?.trim();
    final hasChanged =
        _serviceSuspended != value || _warningMessageUrl != normalizedUrl;

    if (!hasChanged) {
      return false;
    }

    _serviceSuspended = value;
    _warningMessageUrl = value ? normalizedUrl : null;
    Logger.info(
        '🛰️ SYSTEM_STATE: Service suspension ${value ? 'ENABLED' : 'DISABLED'}${value && normalizedUrl != null ? ' ($normalizedUrl)' : ''}');
    return true;
  }

  bool syncServiceSuspended(
      {required bool suspended, String? warningMessageUrl}) {
    return setServiceSuspended(
      suspended,
      warningMessageUrl: warningMessageUrl,
    );
  }
}
