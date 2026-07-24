import 'package:flutter/services.dart';

import 'storage_service.dart';
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

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final bool result =
          await _channel.invokeMethod('isIgnoringBatteryOptimizations');
      return result;
    } catch (e) {
      Logger.error(
          'AutoStartService: Failed to check battery optimization status: $e');
      // Assume ok on failure so we don't nag on unsupported platforms.
      return true;
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

  static Future<bool> isLaunchAtStartupEnabled() async {
    try {
      final result =
          await _channel.invokeMethod<bool>('isLaunchAtStartupEnabled');
      return result ?? false;
    } catch (e) {
      Logger.error(
          'AutoStartService: Failed to read launch-at-startup status: $e');
      rethrow;
    }
  }

  static Future<bool> setLaunchAtStartupEnabled(bool enabled) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'setLaunchAtStartupEnabled',
        {'enabled': enabled},
      );
      final actualValue = result ?? false;
      final storageService = await StorageService.getInstance();
      await storageService.setAutoStartEnabled(actualValue);
      Logger.info('AutoStartService: Launch at startup set to $actualValue');
      return actualValue;
    } catch (e) {
      Logger.error(
          'AutoStartService: Failed to update launch-at-startup status: $e');
      rethrow;
    }
  }
}
