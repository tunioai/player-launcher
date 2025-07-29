import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../models/current_track.dart';
import '../utils/constants.dart';
import '../utils/logger.dart';
import '../core/dependency_injection.dart';

abstract interface class IFailoverService implements Disposable {
  Future<void> initialize();
  Future<void> downloadTrack(CurrentTrack track);
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
  bool _isInitialized = false;
  final Set<String> _downloadingTracks = {};
  // Timer? _cleanupTimer; // Removed automatic cleanup

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
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
    if (currentCount >= AppConstants.maxFailoverTracks && !await file.exists()) {
      Logger.info(
          'FailoverService: Cache limit reached ($currentCount/${AppConstants.maxFailoverTracks}), skipping download');
      return; // Don't download if at limit
    }

    _downloadingTracks.add(track.uuid);

    try {
      Logger.info(
          'FailoverService: Downloading track ${track.artist} - ${track.title}');

      final response = await http.get(
        Uri.parse(track.url),
        headers: {
          'User-Agent': AppConstants.userAgent,
        },
      ).timeout(const Duration(minutes: 5));

      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        Logger.info(
            'FailoverService: Successfully downloaded ${track.fileName} (${response.bodyBytes.length} bytes)');

        // Update count after successful download
        _updateCachedCount();
      } else {
        Logger.error(
            'FailoverService: Failed to download track ${track.uuid}: HTTP ${response.statusCode}');
        throw Exception(
            'Failed to download track: HTTP ${response.statusCode}');
      }
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

    final random = Random();
    final selectedTrack = tracks[random.nextInt(tracks.length)];

    Logger.info(
        'FailoverService: Selected random track: ${selectedTrack.path.split('/').last}');
    return selectedTrack;
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
}

// Helper to fire and forget async operations
void unawaited(Future<void> future) {
  future.catchError((error, stackTrace) {
    Logger.error('Unawaited future error: $error');
    Logger.error('Stack trace: $stackTrace');
  });
}
