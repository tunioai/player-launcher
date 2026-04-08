import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/current_track.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import '../core/dependency_injection.dart';
import 'storage_service.dart';

abstract interface class IFailoverService implements Disposable {
  Future<void> initialize();
  Future<void> downloadTrack(CurrentTrack track);
  Future<String?> cacheWarningMessage(String warningUrl);
  Future<String?> getCachedWarningMessagePath();
  Future<void> clearWarningMessageCache();
  Future<List<File>> getAvailableTracks();
  Future<File?> getRandomTrack();
  Future<void> clearCache();
  int get cachedTracksCount;
  Stream<int> get cachedTracksCountStream;
}

class FailoverService implements IFailoverService {
  final StreamController<int> _cachedTracksCountController =
      StreamController<int>.broadcast();

  late Directory _cacheDirectory;
  late StorageService _storageService;
  bool _isInitialized = false;
  final Set<String> _downloadingTracks = {};
  final Set<String> _downloadingWarningUrls = {};
  // Timer? _cleanupTimer; // Removed automatic cleanup

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _storageService = di.get<StorageService>();
      final documentsDir = await getApplicationDocumentsDirectory();
      _cacheDirectory =
          Directory('${documentsDir.path}/${AppConstants.failoverCacheDir}');

      if (!await _cacheDirectory.exists()) {
        await _cacheDirectory.create(recursive: true);
        Logger.info(
            'FailoverService: Created cache directory at ${_cacheDirectory.path}');
      }

      // Clean up old files on startup
      // Initial cleanup removed - will be handled manually

      _isInitialized = true;
      _updateCachedCount();

      Logger.info('FailoverService: Initialized successfully');
    } catch (e) {
      Logger.error('FailoverService: Failed to initialize: $e');
      rethrow;
    }
  }

  @override
  Future<void> downloadTrack(CurrentTrack track) async {
    if (!_isInitialized) {
      throw StateError('FailoverService not initialized');
    }

    if (_downloadingTracks.contains(track.uuid)) {
      Logger.debug('FailoverService: Track ${track.uuid} already downloading');
      return;
    }

    final file = File('${_cacheDirectory.path}/${track.fileName}');
    if (await file.exists()) {
      // Check if the existing track is still fresh
      final stat = await file.stat();
      final age = DateTime.now().difference(stat.modified);

      if (age < AppConstants.trackCacheTTL) {
        Logger.debug(
            'FailoverService: Track ${track.uuid} already cached and still fresh (${age.inHours}h old)');
        return;
      } else {
        Logger.info(
            'FailoverService: Track ${track.uuid} is expired (${age.inDays}d old), will replace with fresh copy');
        // Don't return - continue to download fresh copy
      }
    }

    // Check if we're at the limit BEFORE downloading
    final currentCount = _getCachedTracksCountSync();
    if (currentCount >= AppConstants.maxFailoverTracks &&
        !await file.exists()) {
      Logger.info(
          'FailoverService: Cache limit reached ($currentCount/${AppConstants.maxFailoverTracks}), skipping download');
      return; // Don't download if at limit
    }

    _downloadingTracks.add(track.uuid);

    try {
      Logger.info(
          'FailoverService: Downloading track ${track.artist} - ${track.title}');

      // Run download in background to prevent blocking audio
      await Future(() async {
        final response = await http.get(
          Uri.parse(track.url),
          headers: {
            'User-Agent': AppConstants.userAgent,
          },
        ).timeout(const Duration(seconds: 30)); // Reduced timeout

        if (response.statusCode == 200) {
          // Write file in background
          await file.writeAsBytes(response.bodyBytes);
          Logger.info(
              'FailoverService: Successfully downloaded ${track.fileName} (${response.bodyBytes.length} bytes)');

          // Update count after successful download
          _updateCachedCount();

          // Clean up excess tracks if needed (in background)
          unawaited(_cleanupExcessTracks());
        } else {
          Logger.error(
              'FailoverService: Failed to download track ${track.uuid}: HTTP ${response.statusCode}');
          throw Exception(
              'Failed to download track: HTTP ${response.statusCode}');
        }
      });
    } catch (e) {
      Logger.error(
          'FailoverService: Error downloading track ${track.uuid}: $e');
      // Clean up partial file if it exists
      if (await file.exists()) {
        await file.delete();
      }
      rethrow;
    } finally {
      _downloadingTracks.remove(track.uuid);
    }
  }

  @override
  Future<String?> cacheWarningMessage(String warningUrl) async {
    if (!_isInitialized) {
      throw StateError('FailoverService not initialized');
    }

    final normalizedUrl = warningUrl.trim();
    if (normalizedUrl.isEmpty) {
      return null;
    }

    if (_downloadingWarningUrls.contains(normalizedUrl)) {
      Logger.debug(
          'FailoverService: Warning message already downloading: $normalizedUrl');
      return _storageService.getCachedWarningMessagePath();
    }

    final existingPath = _storageService.getCachedWarningMessagePath();
    if (existingPath != null && await File(existingPath).exists()) {
      Logger.debug(
          'FailoverService: Warning message already cached at $existingPath');
      return existingPath;
    }

    _downloadingWarningUrls.add(normalizedUrl);

    try {
      final extension = _resolveWarningExtension(normalizedUrl);
      final targetPath = '${_cacheDirectory.path}/warning_message$extension';
      final targetFile = File(targetPath);

      Logger.info(
          'FailoverService: Downloading warning message $normalizedUrl');
      final response = await http.get(
        Uri.parse(normalizedUrl),
        headers: {
          'User-Agent': AppConstants.userAgent,
        },
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        throw Exception(
            'Failed to download warning message: HTTP ${response.statusCode}');
      }

      await targetFile.writeAsBytes(response.bodyBytes, flush: true);
      await _storageService.saveCachedWarningMessagePath(targetPath);
      Logger.info(
          'FailoverService: Warning message cached at $targetPath (${response.bodyBytes.length} bytes)');
      return targetPath;
    } catch (e) {
      Logger.error('FailoverService: Failed to cache warning message: $e');
      return null;
    } finally {
      _downloadingWarningUrls.remove(normalizedUrl);
    }
  }

  @override
  Future<String?> getCachedWarningMessagePath() async {
    if (!_isInitialized) {
      throw StateError('FailoverService not initialized');
    }

    final storedPath = _storageService.getCachedWarningMessagePath();
    if (storedPath == null) {
      return null;
    }

    if (await File(storedPath).exists()) {
      return storedPath;
    }

    await _storageService.clearCachedWarningMessagePath();
    return null;
  }

  @override
  Future<void> clearWarningMessageCache() async {
    if (!_isInitialized) {
      throw StateError('FailoverService not initialized');
    }

    final storedPath = _storageService.getCachedWarningMessagePath();
    if (storedPath != null) {
      final file = File(storedPath);
      if (await file.exists()) {
        await file.delete();
      }
    }

    await _storageService.clearCachedWarningMessagePath();
    Logger.info('FailoverService: Warning message cache cleared');
  }

  @override
  Future<List<File>> getAvailableTracks() async {
    if (!_isInitialized) {
      throw StateError('FailoverService not initialized');
    }

    try {
      final files = await _cacheDirectory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.m4a'))
          .cast<File>()
          .toList();

      // Sort by modification time (newest first) for better failover experience
      files.sort(
          (a, b) => b.statSync().modified.compareTo(a.statSync().modified));

      return files;
    } catch (e) {
      Logger.error('FailoverService: Error getting available tracks: $e');
      return [];
    }
  }

  @override
  Future<File?> getRandomTrack() async {
    final tracks = await getAvailableTracks();
    if (tracks.isEmpty) {
      Logger.warning(
          'FailoverService: No cached tracks available for failover');
      return null;
    }

    final history = _storageService.getFailoverTrackLastPlayed();

    // Track keys are uuids (filename without .m4a). Using uuid keeps this
    // stable across path changes and works cross-platform.
    String keyFor(File file) {
      final last = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : file.path.split('/').last;
      if (last.endsWith('.m4a')) {
        return last.substring(0, last.length - 4);
      }
      return last;
    }

    final candidates = <({File file, String key, int lastPlayed})>[];
    for (final file in tracks) {
      final key = keyFor(file);
      candidates.add((
        file: file,
        key: key,
        lastPlayed: history[key] ?? 0,
      ));
    }

    // Remove stale history entries (deleted cache files).
    unawaited(_storageService
        .pruneFailoverTrackHistory(candidates.map((c) => c.key).toSet()));

    // Pick the least recently played. If multiple have the same oldest
    // timestamp (including 0 = never played), pick randomly among them.
    candidates.sort((a, b) => a.lastPlayed.compareTo(b.lastPlayed));
    final oldestTs = candidates.first.lastPlayed;
    final oldest = candidates.where((c) => c.lastPlayed == oldestTs).toList();

    final selected = oldest.length == 1
        ? oldest.first
        : oldest[Random().nextInt(oldest.length)];

    // Mark now to prevent immediate repeats, even if playback fails.
    unawaited(_storageService.markFailoverTrackPlayed(selected.key));

    Logger.info(
        'FailoverService: Selected LRP failover track: ${selected.file.path.split('/').last} (lastPlayed=$oldestTs)');
    return selected.file;
  }

  @override
  int get cachedTracksCount => _getCachedTracksCountSync();

  @override
  Stream<int> get cachedTracksCountStream =>
      _cachedTracksCountController.stream;

  int _getCachedTracksCountSync() {
    if (!_isInitialized) return 0;

    try {
      return _cacheDirectory
          .listSync()
          .where((entity) => entity is File && entity.path.endsWith('.m4a'))
          .length;
    } catch (e) {
      Logger.error('FailoverService: Error counting cached tracks: $e');
      return 0;
    }
  }

  void _updateCachedCount() {
    final count = _getCachedTracksCountSync();
    _cachedTracksCountController.add(count);
    Logger.debug('FailoverService: Updated cached tracks count: $count');
  }

  Future<void> _cleanupOldTracks() async {
    if (!_isInitialized) return;

    try {
      final files = await _cacheDirectory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.m4a'))
          .cast<File>()
          .toList();

      final now = DateTime.now();
      final expiredFiles = <File>[];
      final validFiles = <File>[];

      // Separate expired and valid files
      for (final file in files) {
        try {
          final stat = await file.stat();
          final age = now.difference(stat.modified);

          if (age >= AppConstants.trackCacheTTL) {
            expiredFiles.add(file);
          } else {
            validFiles.add(file);
          }
        } catch (e) {
          Logger.error('FailoverService: Error checking file ${file.path}: $e');
          // Treat as expired if we can't read stats
          expiredFiles.add(file);
        }
      }

      // Delete all expired files first
      for (final file in expiredFiles) {
        try {
          await file.delete();
          Logger.info(
              'FailoverService: Deleted expired cached track: ${file.path.split('/').last}');
        } catch (e) {
          Logger.error(
              'FailoverService: Failed to delete expired track ${file.path}: $e');
        }
      }

      // If we still have too many valid files, delete oldest ones
      if (validFiles.length > AppConstants.maxFailoverTracks) {
        // Sort valid files by modification time (oldest first)
        validFiles.sort(
            (a, b) => a.statSync().modified.compareTo(b.statSync().modified));

        // Delete oldest valid files beyond the limit
        final excessFiles =
            validFiles.take(validFiles.length - AppConstants.maxFailoverTracks);

        for (final file in excessFiles) {
          try {
            await file.delete();
            Logger.info(
                'FailoverService: Deleted excess cached track: ${file.path.split('/').last}');
          } catch (e) {
            Logger.error(
                'FailoverService: Failed to delete excess track ${file.path}: $e');
          }
        }
      }

      _updateCachedCount();
      final remainingCount = _getCachedTracksCountSync();
      Logger.info(
          'FailoverService: Cleanup completed, ${expiredFiles.length} expired tracks deleted, $remainingCount tracks remaining');
    } catch (e) {
      Logger.error('FailoverService: Error during cleanup: $e');
    }
  }

  Future<void> _cleanupExcessTracks() async {
    final currentCount = _getCachedTracksCountSync();
    if (currentCount > AppConstants.maxFailoverTracks) {
      Logger.info(
          'FailoverService: Have $currentCount tracks, cleaning up excess');
      await _cleanupOldTracks();
    }
  }

  @override
  Future<void> clearCache() async {
    if (!_isInitialized) {
      throw StateError('FailoverService not initialized');
    }

    try {
      Logger.info('FailoverService: Clearing all cached tracks...');

      final files = await _cacheDirectory
          .list()
          .where((entity) => entity is File && entity.path.endsWith('.m4a'))
          .cast<File>()
          .toList();

      int deletedCount = 0;
      for (final file in files) {
        try {
          await file.delete();
          deletedCount++;
          Logger.debug(
              'FailoverService: Deleted cached track: ${file.path.split('/').last}');
        } catch (e) {
          Logger.error(
              'FailoverService: Failed to delete track ${file.path}: $e');
        }
      }

      _updateCachedCount();
      // Cache is gone; reset playback history so new cache starts clean.
      unawaited(_storageService.clearFailoverTrackHistory());
      Logger.info(
          'FailoverService: Cache cleared successfully, deleted $deletedCount tracks');
    } catch (e) {
      Logger.error('FailoverService: Error clearing cache: $e');
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    // _cleanupTimer?.cancel(); // Removed automatic cleanup
    await _cachedTracksCountController.close();
    Logger.info('FailoverService: Disposed');
  }

  String _resolveWarningExtension(String warningUrl) {
    final uri = Uri.tryParse(warningUrl);
    final path = uri?.path.toLowerCase() ?? '';

    if (path.endsWith('.m4a')) return '.m4a';
    if (path.endsWith('.aac')) return '.aac';
    if (path.endsWith('.mp3')) return '.mp3';
    if (path.endsWith('.wav')) return '.wav';
    if (path.endsWith('.ogg')) return '.ogg';

    return '.mp3';
  }
}

// Helper to fire and forget async operations
void unawaited(Future<void> future) {
  future.catchError((error, stackTrace) {
    Logger.error('Unawaited future error: $error');
    Logger.error('Stack trace: $stackTrace');
  });
}
