import '../utils/logger.dart';

/// Holds application-wide runtime flags that can be toggled from backend/config.
class SystemState {
  SystemState._();

  static final SystemState instance = SystemState._();

  bool _offlineMode = false;

  bool get offlineMode => _offlineMode;

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

  /// Applies a nullable offline mode value typically coming from backend config.
  bool syncOfflineMode(bool? value) {
    if (value == null) {
      return false;
    }
    return setOfflineMode(value);
  }
}
