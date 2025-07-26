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
  int get cachedTracksCount;
  Stream<int> get cachedTracksCountStream;
}

class FailoverService implements IFailoverService {
  final StreamController<int> _cachedTracksCountController = 
      StreamController<int>.broadcast();
  
  late Directory _cacheDirectory;
  bool _isInitialized = false;
  final Set<String> _downloadingTracks = {};
  Timer? _cleanupTimer;
  
  @override
  Future<void> initialize() async {
    if (_isInitialized) return;
    
    try {
      final documentsDir = await getApplicationDocumentsDirectory();
      _cacheDirectory = Directory('${documentsDir.path}/${AppConstants.failoverCacheDir}');
      
      if (!await _cacheDirectory.exists()) {
        await _cacheDirectory.create(recursive: true);
        Logger.info('FailoverService: Created cache directory at ${_cacheDirectory.path}');
      }
      
      // Clean up old files on startup
      await _cleanupOldTracks();
      
      // Start periodic cleanup every 10 minutes
      _cleanupTimer = Timer.periodic(const Duration(minutes: 10), (_) {
        unawaited(_cleanupOldTracks());
      });
      
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
      Logger.debug('FailoverService: Track ${track.uuid} already cached');
      return;
    }
    
    _downloadingTracks.add(track.uuid);
    
    try {
      Logger.info('FailoverService: Downloading track ${track.artist} - ${track.title}');
      
      final response = await http.get(
        Uri.parse(track.url),
        headers: {
          'User-Agent': AppConstants.userAgent,
        },
      ).timeout(const Duration(minutes: 5));
      
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        Logger.info('FailoverService: Successfully downloaded ${track.fileName} (${response.bodyBytes.length} bytes)');
        
        // Update count after successful download
        _updateCachedCount();
        
        // Clean up if we have too many tracks
        await _cleanupExcessTracks();
      } else {
        Logger.error('FailoverService: Failed to download track ${track.uuid}: HTTP ${response.statusCode}');
        throw Exception('Failed to download track: HTTP ${response.statusCode}');
      }
    } catch (e) {
      Logger.error('FailoverService: Error downloading track ${track.uuid}: $e');
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
      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      
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
      Logger.warning('FailoverService: No cached tracks available for failover');
      return null;
    }
    
    final random = Random();
    final selectedTrack = tracks[random.nextInt(tracks.length)];
    
    Logger.info('FailoverService: Selected random track: ${selectedTrack.path.split('/').last}');
    return selectedTrack;
  }
  
  @override
  int get cachedTracksCount => _getCachedTracksCountSync();
  
  @override
  Stream<int> get cachedTracksCountStream => _cachedTracksCountController.stream;
  
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
      
      if (files.length <= AppConstants.maxFailoverTracks) {
        return; // No cleanup needed
      }
      
      // Sort by modification time (oldest first)
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      
      // Delete oldest files beyond the limit
      final filesToDelete = files.take(files.length - AppConstants.maxFailoverTracks);
      
      for (final file in filesToDelete) {
        try {
          await file.delete();
          Logger.info('FailoverService: Deleted old cached track: ${file.path.split('/').last}');
        } catch (e) {
          Logger.error('FailoverService: Failed to delete old track ${file.path}: $e');
        }
      }
      
      _updateCachedCount();
      Logger.info('FailoverService: Cleanup completed, kept ${AppConstants.maxFailoverTracks} tracks');
    } catch (e) {
      Logger.error('FailoverService: Error during cleanup: $e');
    }
  }
  
  Future<void> _cleanupExcessTracks() async {
    final currentCount = _getCachedTracksCountSync();
    if (currentCount > AppConstants.maxFailoverTracks) {
      Logger.info('FailoverService: Have $currentCount tracks, cleaning up excess');
      await _cleanupOldTracks();
    }
  }
  
  @override
  Future<void> dispose() async {
    _cleanupTimer?.cancel();
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