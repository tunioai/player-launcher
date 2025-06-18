import 'dart:developer' as developer;

enum LogLevel {
  debug,
  info,
  warning,
  error,
}

class Logger {
  static const bool _isDebugMode = true;

  static void debug(String message, [String? tag]) {
    _log(LogLevel.debug, message, tag);
  }

  static void info(String message, [String? tag]) {
    _log(LogLevel.info, message, tag);
  }

  static void warning(String message, [String? tag]) {
    _log(LogLevel.warning, message, tag);
  }

  static void error(String message,
      [String? tag, Object? error, StackTrace? stackTrace]) {
    _log(LogLevel.error, message, tag);
    if (error != null) {
      _log(LogLevel.error, 'Error details: $error', tag);
    }
    if (stackTrace != null && _isDebugMode) {
      _log(LogLevel.error, 'Stack trace: $stackTrace', tag);
    }
  }

  static void _log(LogLevel level, String message, String? tag) {
    if (!_isDebugMode && level == LogLevel.debug) {
      return;
    }

    final timestamp = DateTime.now().toIso8601String();
    final levelStr = level.name.toUpperCase().padRight(7);
    final tagStr = tag != null ? '[$tag] ' : '';
    final formattedMessage = '$timestamp $levelStr $tagStr$message';

    switch (level) {
      case LogLevel.debug:
        developer.log(formattedMessage, name: 'DEBUG');
        break;
      case LogLevel.info:
        developer.log(formattedMessage, name: 'INFO');
        break;
      case LogLevel.warning:
        developer.log(formattedMessage, name: 'WARNING', level: 900);
        break;
      case LogLevel.error:
        developer.log(formattedMessage, name: 'ERROR', level: 1000);
        break;
    }
  }
}
