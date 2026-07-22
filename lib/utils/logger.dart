import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';

enum LogLevel {
  debug,
  info,
  warning,
  error,
}

class Logger {
  // Persistent on-disk sink so a packaged build (no visible stdout) still
  // leaves a log the user can hand over after a crash. Kept open for the whole
  // session; writes are synchronous so the last lines survive even a hard
  // native crash (they reach the OS file cache, which outlives the process).
  static RandomAccessFile? _logHandle;
  static String? _logFilePath;

  /// Absolute path of the current log file, or null before file logging is
  /// initialized. Surface this so the user knows what to send.
  static String? get logFilePath => _logFilePath;

  /// Opens (and size-rotates) the log file under [directoryPath]. Safe to call
  /// once at startup; never throws — logging must not break app launch.
  static Future<void> initializeFileLogging(String directoryPath) async {
    try {
      final dir = Directory(directoryPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final path = '${dir.path}${Platform.pathSeparator}tunio.log';
      final file = File(path);
      // Rotate at ~2 MB, keeping a single previous copy (tunio.log.1).
      if (file.existsSync() && file.lengthSync() > 2 * 1024 * 1024) {
        final previous = File('$path.1');
        if (previous.existsSync()) {
          previous.deleteSync();
        }
        file.renameSync(previous.path);
      }
      _logHandle = File(path).openSync(mode: FileMode.append);
      _logFilePath = path;
      _writeLine(
          '===== session start ${DateTime.now().toIso8601String()} =====');
    } catch (e) {
      // ignore: avoid_print
      print('Logger: failed to initialize file logging: $e');
    }
  }

  static void _writeLine(String line) {
    try {
      _logHandle?.writeStringSync('$line\n');
    } catch (_) {
      // Never let a logging failure propagate.
    }
  }

  // Stdout is the only reliably visible channel in `flutter run --release`.
  // Keep it low-noise: always print warnings/errors; print debug/info only in
  // debug builds.
  static bool _shouldPrint(LogLevel level) {
    if (kDebugMode) return true;
    return level == LogLevel.warning || level == LogLevel.error;
  }

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
    // Always persist the stack trace (file + stdout); it is the whole point of
    // having a crash log to hand over.
    if (stackTrace != null) {
      _log(LogLevel.error, 'Stack trace: $stackTrace', tag);
    }
  }

  static void _log(LogLevel level, String message, String? tag) {
    final timestamp = DateTime.now().toIso8601String();
    final levelStr = level.name.toUpperCase().padRight(7);
    final tagStr = tag != null ? '[$tag] ' : '';
    final formattedMessage = '$timestamp $levelStr $tagStr$message';

    // Persist every level to the on-disk log regardless of the stdout filter.
    _writeLine(formattedMessage);

    // Output to both developer.log and print for Flutter debug console
    switch (level) {
      case LogLevel.debug:
        developer.log(formattedMessage, name: 'DEBUG');
        // ignore: avoid_print
        if (_shouldPrint(level)) print('🔍 DEBUG: $tagStr$message');
        break;
      case LogLevel.info:
        developer.log(formattedMessage, name: 'INFO');
        // ignore: avoid_print
        if (_shouldPrint(level)) print('ℹ️ INFO: $tagStr$message');
        break;
      case LogLevel.warning:
        developer.log(formattedMessage, name: 'WARNING', level: 900);
        // ignore: avoid_print
        if (_shouldPrint(level)) print('⚠️ WARNING: $tagStr$message');
        break;
      case LogLevel.error:
        developer.log(formattedMessage, name: 'ERROR', level: 1000);
        // ignore: avoid_print
        if (_shouldPrint(level)) print('❌ ERROR: $tagStr$message');
        break;
    }
  }

  static void logDiagnosticInfo(
    String context, {
    String? audioState,
    String? networkState,
    String? controllerState,
    int? bufferSeconds,
    int? pingMs,
    bool? isRetrying,
    String? currentToken,
    String? streamUrl,
  }) {
    info('🩺 DIAGNOSTIC_$context: === SYSTEM STATE DUMP ===');
    info(
        '🩺 DIAGNOSTIC_$context: Timestamp: ${DateTime.now().toIso8601String()}');

    if (audioState != null) {
      info('🩺 DIAGNOSTIC_$context: Audio State: $audioState');
    }

    if (networkState != null) {
      info('🩺 DIAGNOSTIC_$context: Network State: $networkState');
    }

    if (controllerState != null) {
      info('🩺 DIAGNOSTIC_$context: Controller State: $controllerState');
    }

    if (bufferSeconds != null) {
      info('🩺 DIAGNOSTIC_$context: Buffer: ${bufferSeconds}s');
    }

    if (pingMs != null) {
      info('🩺 DIAGNOSTIC_$context: Ping: ${pingMs}ms');
    }

    if (isRetrying != null) {
      info('🩺 DIAGNOSTIC_$context: Is Retrying: $isRetrying');
    }

    if (currentToken != null) {
      info('🩺 DIAGNOSTIC_$context: Has Token: ${currentToken.isNotEmpty}');
    }

    if (streamUrl != null) {
      info(
          '🩺 DIAGNOSTIC_$context: Stream URL: ${streamUrl.isNotEmpty ? '[SET]' : '[EMPTY]'}');
    }

    info('🩺 DIAGNOSTIC_$context: === END SYSTEM STATE ===');
  }
}
