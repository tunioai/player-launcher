import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppReleaseInfo {
  const AppReleaseInfo({
    required this.version,
    required this.build,
    required this.apkUrl,
    required this.publishedAt,
  });

  final String version;
  final int build;
  final String apkUrl;
  final DateTime? publishedAt;
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.isUpdateAvailable,
    this.latestRelease,
    this.message,
  });

  final String currentVersion;
  final bool isUpdateAvailable;
  final AppReleaseInfo? latestRelease;
  final String? message;
}

class AppUpdateService {
  static const String _manifestUrl =
      'https://cdn.tunio.ai/releases/spot/manifest.json';
  static const String _appFlavor =
      String.fromEnvironment('APP_FLAVOR', defaultValue: 'play');
  static const MethodChannel _channel = MethodChannel('ai.tunio/updater');

  bool get isSupported =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _appFlavor == 'standalone';

  Future<UpdateCheckResult> checkForUpdate() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version.trim();
    final currentBuild = int.tryParse(packageInfo.buildNumber.trim()) ?? 0;

    if (!isSupported) {
      return UpdateCheckResult(
        currentVersion: currentVersion,
        isUpdateAvailable: false,
        message: 'Self-update is disabled for this build.',
      );
    }

    final release = await _fetchLatestRelease();
    if (release == null) {
      return UpdateCheckResult(
        currentVersion: currentVersion,
        isUpdateAvailable: false,
        message: 'Unable to fetch latest release.',
      );
    }

    final versionCompare = _compareVersions(release.version, currentVersion);
    final hasUpdate = versionCompare > 0 ||
        (versionCompare == 0 && release.build > currentBuild);

    return UpdateCheckResult(
      currentVersion: currentVersion,
      isUpdateAvailable: hasUpdate,
      latestRelease: release,
      message: hasUpdate ? null : 'You already have the latest version.',
    );
  }

  Future<File> downloadApk(
    AppReleaseInfo release, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = HttpClient();
    final uri = Uri.parse(release.apkUrl);
    final request = await client.getUrl(uri);
    try {
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('Download failed with HTTP ${response.statusCode}');
      }

      final tempDir = await getTemporaryDirectory();
      final fileName = 'tunio-player-${release.version}.apk';
      final file = File('${tempDir.path}/$fileName');

      if (await file.exists()) {
        await file.delete();
      }

      final sink = file.openWrite();
      final total = response.contentLength;
      var received = 0;

      await for (final chunk in response) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }

      await sink.flush();
      await sink.close();

      return file;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> canRequestPackageInstalls() async {
    if (!isSupported) return false;
    final allowed =
        await _channel.invokeMethod<bool>('canRequestPackageInstalls');
    return allowed ?? false;
  }

  Future<void> openUnknownSourcesSettings() async {
    if (!isSupported) return;
    await _channel.invokeMethod<void>('openUnknownAppSourcesSettings');
  }

  Future<void> installApk(File file) async {
    if (!isSupported) {
      throw Exception('Self-update is disabled for this build.');
    }
    await _channel.invokeMethod<void>('installApk', {'path': file.path});
  }

  Future<AppReleaseInfo?> _fetchLatestRelease() async {
    final uri = Uri.parse(_manifestUrl).replace(
      queryParameters: {
        'ts': DateTime.now().millisecondsSinceEpoch.toString(),
      },
    );

    final response = await http.get(
      uri,
      headers: const {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
        'User-Agent': 'TunioSpotStandaloneUpdater',
      },
    );

    if (response.statusCode != HttpStatus.ok) {
      return null;
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final rawVersion = (data['version'] as String? ?? '').trim();
    final version = _normalizeVersion(rawVersion);
    if (version.isEmpty) {
      return null;
    }

    final build = _parseBuild(data['build']);
    if (build <= 0) {
      return null;
    }

    final rawApkUrl = (data['apk_url'] as String? ?? '').trim();
    if (rawApkUrl.isEmpty) {
      return null;
    }

    final apkUrl = _resolveApkUrl(rawApkUrl);
    if (apkUrl == null) {
      return null;
    }

    final publishedAtRaw = data['published_at'] as String?;
    final publishedAt = publishedAtRaw == null
        ? null
        : DateTime.tryParse(publishedAtRaw)?.toLocal();

    return AppReleaseInfo(
      version: version,
      build: build,
      apkUrl: apkUrl,
      publishedAt: publishedAt,
    );
  }

  int _parseBuild(dynamic buildValue) {
    if (buildValue is int) {
      return buildValue;
    }
    if (buildValue is String) {
      return int.tryParse(buildValue.trim()) ?? 0;
    }
    return 0;
  }

  String? _resolveApkUrl(String rawApkUrl) {
    final uri = Uri.tryParse(rawApkUrl);
    if (uri == null) {
      return null;
    }

    if (uri.hasScheme && uri.host.isNotEmpty) {
      return uri.toString();
    }

    final manifestUri = Uri.parse(_manifestUrl);
    return manifestUri.resolveUri(uri).toString();
  }

  String _normalizeVersion(String rawVersion) {
    var normalized = rawVersion.trim();
    if (normalized.startsWith('v') || normalized.startsWith('V')) {
      normalized = normalized.substring(1);
    }

    final plusIndex = normalized.indexOf('+');
    if (plusIndex > 0) {
      normalized = normalized.substring(0, plusIndex);
    }

    return normalized;
  }

  int _compareVersions(String left, String right) {
    final leftParts = _parseVersionParts(left);
    final rightParts = _parseVersionParts(right);
    final maxLen = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var i = 0; i < maxLen; i++) {
      final l = i < leftParts.length ? leftParts[i] : 0;
      final r = i < rightParts.length ? rightParts[i] : 0;
      if (l != r) {
        return l.compareTo(r);
      }
    }

    return 0;
  }

  List<int> _parseVersionParts(String version) {
    return _normalizeVersion(version)
        .split('.')
        .map(
            (part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }
}
