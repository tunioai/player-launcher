import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

class PlatformInfo {
  static PackageInfo? _packageInfo;

  // Initialize package info (call this at app startup)
  static Future<void> initialize() async {
    _packageInfo = await PackageInfo.fromPlatform();
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
    String hostname = '';

    try {
      hostname = Platform.localHostname;
    } catch (e) {
      hostname = 'unknown';
    }

    // Capitalize first letter of OS name
    os = os[0].toUpperCase() + os.substring(1);

    return '$os/$hostname';
  }

  static Map<String, String> get apiHeaders {
    return {
      'User-Agent': userAgent,
      'Platform': platform,
      'Content-Type': 'application/json',
    };
  }
}
