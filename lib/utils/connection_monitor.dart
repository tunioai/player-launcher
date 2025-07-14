import 'dart:async';
import '../utils/logger.dart';

class ConnectionMonitor {
  static final Map<String, DateTime> _activeConnections = {};
  static int _connectionCounter = 0;
  static Timer? _cleanupTimer;
  static const Duration _maxConnectionAge = Duration(minutes: 5);

  static String trackConnection(String url) {
    _connectionCounter++;
    final connectionId = 'conn_$_connectionCounter';
    _activeConnections[connectionId] = DateTime.now();

    Logger.info(
        '📊 ConnectionMonitor: NEW connection [$connectionId] to $url. Total active: ${_activeConnections.length}',
        'ConnectionMonitor');

    _startCleanupTimer();
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

  static void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _cleanupStaleConnections();
    });
  }

  static void _cleanupStaleConnections() {
    final now = DateTime.now();
    final staleConnections = <String>[];

    _activeConnections.forEach((id, startTime) {
      if (now.difference(startTime) > _maxConnectionAge) {
        staleConnections.add(id);
      }
    });

    for (final id in staleConnections) {
      Logger.warning('📊 ConnectionMonitor: Cleaning up stale connection [$id]',
          'ConnectionMonitor');
      _activeConnections.remove(id);
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

  static void dispose() {
    _cleanupTimer?.cancel();
    _activeConnections.clear();
  }
}
