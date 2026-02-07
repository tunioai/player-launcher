import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'logger.dart';

class PlatformInfo {
  static PackageInfo? _packageInfo;
  static String? _deviceId;
  static String? _deviceModel;
  static String? _deviceUuid;
  static const String _deviceUuidKey = 'device_uuid';

  // Initialize package info and device info (call this at app startup)
  static Future<void> initialize() async {
    _packageInfo = await PackageInfo.fromPlatform();
    await _initializeDeviceInfo();
    await _initializeDeviceUuid();
  }

  static Future<void> _initializeDeviceInfo() async {
    try {
      final deviceInfo = DeviceInfoPlugin();

      if (kIsWeb) {
        _deviceId = 'web';
        _deviceModel = 'Browser';
        return;
      }

      switch (Platform.operatingSystem) {
        case 'android':
          final androidInfo = await deviceInfo.androidInfo;
          _deviceId = androidInfo.id;
          _deviceModel = '${androidInfo.manufacturer}_${androidInfo.model}';
          final shortId = _deviceId != null && _deviceId!.length >= 8
              ? _deviceId!.substring(0, 8)
              : _deviceId;
          Logger.info('Device initialized: $_deviceModel (ID: $shortId...)');
          break;

        case 'ios':
          final iosInfo = await deviceInfo.iosInfo;
          _deviceId = iosInfo.identifierForVendor ?? 'unknown';
          _deviceModel = iosInfo.model;
          break;

        case 'macos':
          final macInfo = await deviceInfo.macOsInfo;
          _deviceId = macInfo.systemGUID ?? 'unknown';
          _deviceModel = macInfo.model;
          break;

        case 'windows':
          final windowsInfo = await deviceInfo.windowsInfo;
          _deviceId = windowsInfo.deviceId;
          _deviceModel = windowsInfo.computerName;
          final shortId = _deviceId != null && _deviceId!.length >= 8
              ? _deviceId!.substring(0, 8)
              : _deviceId;
          Logger.info('Device initialized: $_deviceModel (ID: $shortId...)');
          break;

        case 'linux':
          final linuxInfo = await deviceInfo.linuxInfo;
          _deviceId = linuxInfo.machineId ?? 'unknown';
          _deviceModel = 'Linux';
          break;

        default:
          _deviceId = 'unknown';
          _deviceModel = 'unknown';
          Logger.warning('Unknown platform: ${Platform.operatingSystem}');
      }
    } catch (e) {
      Logger.error('Failed to get device info: $e');
      _deviceId = 'unknown';
      _deviceModel = 'unknown';
    }
  }

  static Future<void> _initializeDeviceUuid() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_deviceUuidKey);
      if (stored != null && stored.isNotEmpty) {
        _deviceUuid = stored;
        return;
      }

      _deviceUuid = _generateUuidV4();
      await prefs.setString(_deviceUuidKey, _deviceUuid!);
    } catch (e) {
      Logger.error('Failed to initialize device UUID: $e');
      _deviceUuid = null;
    }
  }

  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant

    String hex(int value) => value.toRadixString(16).padLeft(2, '0');
    final b = bytes.map(hex).toList();

    return '${b[0]}${b[1]}${b[2]}${b[3]}-'
        '${b[4]}${b[5]}-'
        '${b[6]}${b[7]}-'
        '${b[8]}${b[9]}-'
        '${b[10]}${b[11]}${b[12]}${b[13]}${b[14]}${b[15]}';
  }

  static String get userAgent {
    final version = _packageInfo?.version ?? '1.0.0';
    final buildNumber = _packageInfo?.buildNumber ?? '1';
    return 'TunioSpot $version+$buildNumber';
  }

  static String get platform {
    if (kIsWeb) {
      return 'Web';
    }

    String os = Platform.operatingSystem;
    os = os[0].toUpperCase() + os.substring(1);

    // Use device model and first 8 chars of device ID for uniqueness
    final deviceInfo = _deviceModel ?? 'unknown';
    final shortId = _deviceId != null && _deviceId!.length > 8
        ? _deviceId!.substring(0, 8)
        : (_deviceId ?? 'unknown');

    return '$os/$deviceInfo/$shortId';
  }

  // Get full device ID for server-side tracking
  static String get deviceId => _deviceId ?? 'unknown';

  // Get stable device UUID for server-side tracking
  static String get deviceUuid => _deviceUuid ?? 'unknown';

  // Get device model
  static String get deviceModel => _deviceModel ?? 'unknown';

  static Map<String, String> get apiHeaders => getApiHeaders();

  static Map<String, String> getApiHeaders({int? ping}) {
    final headers = {
      'User-Agent': userAgent,
      'X-Platform': platform,
      'Content-Type': 'application/json',
    };

    if (ping != null) {
      headers['X-Ping'] = ping.toString();
    }

    if (_deviceUuid != null && _deviceUuid!.isNotEmpty) {
      headers['X-Device-UUID'] = _deviceUuid!;
    }

    return headers;
  }
}
