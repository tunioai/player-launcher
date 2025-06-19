import 'package:flutter/services.dart';
import '../utils/logger.dart';

class AutoStartService {
  static const MethodChannel _channel =
      MethodChannel('com.example.tunio_radio_player/autostart');

  static Future<bool> isAutoStarted() async {
    try {
      final bool result = await _channel.invokeMethod('isAutoStarted');
      Logger.info('AutoStartService: App was auto-started: $result');
      return result;
    } catch (e) {
      Logger.error('AutoStartService: Failed to check auto-start status: $e');
      return false;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      final bool result =
          await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
      Logger.info(
          'AutoStartService: Battery optimization request result: $result');
      return result;
    } catch (e) {
      Logger.error(
          'AutoStartService: Failed to request battery optimization: $e');
      return false;
    }
  }

  static Future<bool> openSystemLauncher() async {
    try {
      final bool result = await _channel.invokeMethod('openSystemLauncher');
      Logger.info('AutoStartService: System launcher opened: $result');
      return result;
    } catch (e) {
      Logger.error('AutoStartService: Failed to open system launcher: $e');
      return false;
    }
  }
}
