import '../utils/logger.dart';

class ConnectionMonitor {
  static final Map<String, DateTime> _activeConnections = {};
  static int _connectionCounter = 0;

  static String trackConnection(String url) {
    _connectionCounter++;
    final connectionId = 'conn_$_connectionCounter';
    _activeConnections[connectionId] = DateTime.now();

    Logger.info(
        '📊 ConnectionMonitor: NEW connection [$connectionId] to $url. Total active: ${_activeConnections.length}',
        'ConnectionMonitor');

    return connectionId;
  }

  static void releaseConnection(String connectionId) {
    final startTime = _activeConnections.remove(connectionId);
    if (startTime != null) {
      final duration = DateTime.now().difference(startTime);
      Logger.info(
          '📊 ConnectionMonitor: CLOSED connection [$connectionId] after ${duration.inSeconds}s. Remaining active: ${_activeConnections.length}',
          'ConnectionMonitor');
    }
  }

  static void logActiveConnections() {
    if (_activeConnections.isNotEmpty) {
      Logger.warning(
          '📊 ConnectionMonitor: ${_activeConnections.length} active connections detected:',
          'ConnectionMonitor');

      _activeConnections.forEach((id, startTime) {
        final duration = DateTime.now().difference(startTime);
        Logger.warning(
            '📊 ConnectionMonitor: - [$id] active for ${duration.inSeconds}s',
            'ConnectionMonitor');
      });
    } else {
      Logger.info(
          '📊 ConnectionMonitor: No active connections', 'ConnectionMonitor');
    }
  }

  static int get activeConnectionCount => _activeConnections.length;
}
