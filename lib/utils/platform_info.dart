import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../services/credential_store.dart';
import 'logger.dart';
import 'prefs_guard.dart';

class PlatformInfo {
  static PackageInfo? _packageInfo;
  static bool _isTv = false;
  static String? _deviceId;
  static String? _deviceModel;
  static String? _deviceUuid;
  static String? _localIp;
  static DateTime? _localIpUpdatedAt;
  static String? _fallbackIp;
  static DateTime? _fallbackIpUpdatedAt;
  static final NetworkInfo _networkInfo = NetworkInfo();
  static const String _deviceUuidKey = 'device_uuid';
  static const Duration _localIpTtl = Duration(minutes: 5);
  static const Duration _localIpMissTtl = Duration(seconds: 15);
  static const Duration _fallbackIpTtl = Duration(minutes: 1);

  // Initialize package info and device info (call this at app startup)
  static Future<void> initialize() async {
    _packageInfo = await PackageInfo.fromPlatform();
    await _initializeDeviceInfo();
    await _initializeDeviceUuid();
    await _initializeLocalIp();
    await _initializeFallbackIp();
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
          // Android TV boxes/sticks report these device features; phones don't.
          // Used to switch the UI into D-pad (directional) navigation so the PIN
          // field can be focused and the on-screen keyboard opened with a remote.
          _isTv = androidInfo.systemFeatures
                  .contains('android.software.leanback') ||
              androidInfo.systemFeatures
                  .contains('android.hardware.type.television');
          final shortId = _deviceId != null && _deviceId!.length >= 8
              ? _deviceId!.substring(0, 8)
              : _deviceId;
          Logger.info(
              'Device initialized: $_deviceModel (ID: $shortId..., tv: $_isTv)');
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
      final store = await CredentialStore.getInstance();
      var uuid = store.get(CredentialStore.deviceUuidKey) ??
          await _deviceUuidFromPrefs();
      uuid ??= _generateUuidV4();
      await store.set(CredentialStore.deviceUuidKey, uuid);
      await _mirrorDeviceUuidToPrefs(uuid);
      _deviceUuid = uuid;
    } catch (e) {
      Logger.error('Failed to initialize device UUID: $e');
      _deviceUuid = null;
    }
  }

  static Future<String?> _deviceUuidFromPrefs() async {
    try {
      final stored = (await PrefsGuard.getInstance()).getString(_deviceUuidKey);
      if (stored == null || stored.isEmpty) return null;
      return stored;
    } catch (e) {
      Logger.error('Failed to read device UUID from prefs: $e');
      return null;
    }
  }

  // Kept in both stores for the same reason as the token in StorageService:
  // this UUID is the device identity the backend sees (X-Device-UUID), so
  // regenerating it makes an existing point look like a brand new device. The
  // prefs copy covers a downgrade to a pre-CredentialStore build and a lost
  // credentials.json; CredentialStore covers prefs corruption.
  static Future<void> _mirrorDeviceUuidToPrefs(String uuid) async {
    try {
      final prefs = await PrefsGuard.getInstance();
      if (prefs.getString(_deviceUuidKey) == uuid) return;
      await prefs.setString(_deviceUuidKey, uuid);
    } catch (e) {
      Logger.error('Failed to mirror device UUID to prefs: $e');
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

  /// Version and build as one string, e.g. "1.8.0+31".
  static String get appVersion {
    final version = _packageInfo?.version ?? '1.0.0';
    final buildNumber = _packageInfo?.buildNumber ?? '1';
    return '$version+$buildNumber';
  }

  static String get userAgent => 'TunioSpot $appVersion';

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

  /// True on Android TV (leanback/television device features). Set during
  /// initialize(); false until then and on non-TV platforms.
  static bool get isTv => _isTv;

  static Map<String, String> get apiHeaders => getApiHeaders();

  static String? get localWifiIp => _localIp;

  static String? get bestEffortIp {
    unawaited(_refreshLocalIp());
    if (_localIp != null && _localIp!.isNotEmpty) {
      return _localIp;
    }
    unawaited(_refreshFallbackIp());
    return _fallbackIp;
  }

  static Map<String, String> getApiHeaders({int? ping}) {
    final headers = {
      'User-Agent': userAgent,
      'X-Platform': platform,
      'Content-Type': 'application/json',
    };

    unawaited(_refreshLocalIp());
    if (_localIp != null && _localIp!.isNotEmpty) {
      headers['X-Local-Ip'] = _localIp!;
    }

    if (ping != null) {
      headers['X-Ping'] = ping.toString();
    }

    if (_deviceUuid != null && _deviceUuid!.isNotEmpty) {
      headers['X-Device-UUID'] = _deviceUuid!;
    }

    return headers;
  }

  static Future<void> _initializeLocalIp() async {
    await _refreshLocalIp(force: true);
  }

  static Future<void> _initializeFallbackIp() async {
    await _refreshFallbackIp(force: true);
  }

  static Future<void> _refreshLocalIp({bool force = false}) async {
    if (kIsWeb) {
      return;
    }

    final lastUpdated = _localIpUpdatedAt;
    final ttl = _localIp == null ? _localIpMissTtl : _localIpTtl;
    if (!force &&
        lastUpdated != null &&
        DateTime.now().difference(lastUpdated) < ttl) {
      return;
    }

    try {
      final wifiIp = await _networkInfo.getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty && wifiIp != '0.0.0.0') {
        _localIp = wifiIp;
      } else {
        _localIp = null;
      }
      _localIpUpdatedAt = DateTime.now();
    } catch (e) {
      Logger.debug('Failed to refresh local Wi-Fi IP: $e');
    }
  }

  static Future<void> _refreshFallbackIp({bool force = false}) async {
    if (kIsWeb) {
      return;
    }

    final lastUpdated = _fallbackIpUpdatedAt;
    final ttl = _fallbackIp == null ? _localIpMissTtl : _fallbackIpTtl;
    if (!force &&
        lastUpdated != null &&
        DateTime.now().difference(lastUpdated) < ttl) {
      return;
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      String? candidate;
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          if (address.isLoopback || _isLinkLocal(ip)) {
            continue;
          }
          if (_isPrivateIpv4(ip)) {
            candidate = ip;
            break;
          }
          candidate ??= ip;
        }
        if (candidate != null && _isPrivateIpv4(candidate)) {
          break;
        }
      }

      _fallbackIp = candidate;
      _fallbackIpUpdatedAt = DateTime.now();
    } catch (e) {
      Logger.debug('Failed to refresh fallback IP: $e');
    }
  }

  static bool _isLinkLocal(String ip) {
    return ip.startsWith('169.254.');
  }

  static bool _isPrivateIpv4(String ip) {
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    if (ip.startsWith('172.')) {
      final parts = ip.split('.');
      if (parts.length < 2) return false;
      final second = int.tryParse(parts[1]) ?? 0;
      return second >= 16 && second <= 31;
    }
    return false;
  }
}
