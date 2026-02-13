import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import '../../utils/logger.dart';

typedef HlsPlaylistInfoCallback = void Function(HlsPlaylistInfo info);

final class HlsStreamAudioSource extends StreamAudioSource {
  final Uri playlistUri;
  final Map<String, String> headers;
  final Duration refreshInterval;
  final Duration segmentRequestTimeout;
  final int maxRetryAttempts;
  final HlsPlaylistInfoCallback? onPlaylistInfo;

  final List<_HlsStreamSession> _sessions = [];
  bool _isDisposed = false;

  HlsStreamAudioSource({
    required this.playlistUri,
    this.headers = const {},
    this.refreshInterval = const Duration(seconds: 1),
    this.segmentRequestTimeout = const Duration(seconds: 10),
    this.maxRetryAttempts = 3,
    this.onPlaylistInfo,
    super.tag,
  });

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    if (_isDisposed) {
      throw Exception('HLS source already disposed');
    }

    final session = _HlsStreamSession(
      playlistUri: playlistUri,
      headers: headers,
      refreshInterval: refreshInterval,
      segmentRequestTimeout: segmentRequestTimeout,
      maxRetryAttempts: maxRetryAttempts,
      onPlaylistInfo: onPlaylistInfo,
    );
    _sessions.add(session);
    session.done.then((_) {
      _sessions.remove(session);
    });

    final stream = session.start();

    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: null,
      offset: null,
      contentType: 'audio/aac',
      stream: stream,
    );
  }

  Future<void> close() async {
    if (_isDisposed) return;
    for (final session in List<_HlsStreamSession>.from(_sessions)) {
      await session.dispose();
      _sessions.remove(session);
    }
    _isDisposed = true;
  }
}

class HlsPlaylistInfo {
  final int segmentCount;
  final Duration segmentDuration;

  const HlsPlaylistInfo({
    required this.segmentCount,
    required this.segmentDuration,
  });

  Duration get totalDuration =>
      Duration(milliseconds: segmentDuration.inMilliseconds * segmentCount);
}

class _HlsStreamSession {
  final Uri playlistUri;
  final Map<String, String> headers;
  final Duration refreshInterval;
  final Duration segmentRequestTimeout;
  final int maxRetryAttempts;
  final HlsPlaylistInfoCallback? onPlaylistInfo;

  final StreamController<List<int>> _controller = StreamController<List<int>>();
  final http.Client _client = http.Client();
  final Completer<void> _doneCompleter = Completer<void>();

  bool _cancelled = false;
  int? _lastSequence;

  _HlsStreamSession({
    required this.playlistUri,
    required this.headers,
    required this.refreshInterval,
    required this.segmentRequestTimeout,
    required this.maxRetryAttempts,
    this.onPlaylistInfo,
  });

  Stream<List<int>> start() {
    _controller.onCancel = () {
      dispose();
    };

    _pumpSegments();
    return _controller.stream;
  }

  Future<void> get done => _doneCompleter.future;

  Future<void> dispose() async {
    _cancelled = true;
    _client.close();
    await _doneCompleter.future;
  }

  void _pumpSegments() {
    unawaited(_runLoop());
  }

  Future<void> _runLoop() async {
    try {
      while (!_cancelled && !_controller.isClosed) {
        try {
          final playlist = await _fetchPlaylist();
          if (onPlaylistInfo != null) {
            final info = HlsPlaylistInfo(
              segmentCount: playlist.segments.length,
              segmentDuration: playlist.targetDuration ??
                  (playlist.segments.isNotEmpty
                      ? playlist.segments.first.duration
                      : const Duration(seconds: 5)),
            );
            onPlaylistInfo!(info);
          }
          _lastSequence ??= playlist.mediaSequence - 1;

          for (final segment in playlist.segments) {
            if (_cancelled || _controller.isClosed) break;

            if (segment.sequence > (_lastSequence ?? -1)) {
              final bytes = await _fetchSegment(segment.uri);
              if (_cancelled || _controller.isClosed) break;

              if (bytes != null && bytes.isNotEmpty) {
                _controller.add(bytes);
                _lastSequence = segment.sequence;
              } else {
                Logger.warning(
                    'HLS segment skipped after retries for ${segment.uri}');
              }
            }
          }
        } catch (e, stackTrace) {
          if (_cancelled || _controller.isClosed) {
            break;
          }
          Logger.warning('HLS playlist fetch error: $e');
          Logger.debug('$stackTrace');
          await Future.delayed(refreshInterval);
        }

        await Future.delayed(refreshInterval);
      }
    } finally {
      if (!_controller.isClosed) {
        await _controller.close();
      }
      if (!_doneCompleter.isCompleted) {
        _doneCompleter.complete();
      }
    }
  }

  Future<_ParsedHlsPlaylist> _fetchPlaylist() async {
    final request = http.Request('GET', playlistUri);
    if (headers.isNotEmpty) {
      request.headers.addAll(headers);
    }

    final response = await _client.send(request).timeout(segmentRequestTimeout,
        onTimeout: () {
      throw TimeoutException(
          'Playlist request timed out after ${segmentRequestTimeout.inSeconds}s');
    });

    if (response.statusCode != 200) {
      throw HttpException(
          'Playlist request failed with status ${response.statusCode}');
    }

    final body = await response.stream.bytesToString();
    return _ParsedHlsPlaylist.parse(playlistUri, body);
  }

  Future<List<int>?> _fetchSegment(Uri uri) async {
    var attempt = 0;
    while (!_cancelled && !_controller.isClosed) {
      try {
        final request = http.Request('GET', uri);
        if (headers.isNotEmpty) {
          request.headers.addAll(headers);
        }

        final response = await _client
            .send(request)
            .timeout(segmentRequestTimeout, onTimeout: () {
          throw TimeoutException(
              'Segment request timed out after ${segmentRequestTimeout.inSeconds}s for $uri');
        });

        if (response.statusCode != 200) {
          throw HttpException(
              'Segment request failed with status ${response.statusCode} for $uri');
        }

        final bytes = await response.stream.toBytes();
        return bytes;
      } catch (e, stackTrace) {
        attempt++;
        if (attempt >= maxRetryAttempts) {
          Logger.error('HLS segment fetch failed repeatedly for $uri: $e');
          Logger.debug('$stackTrace');
          return null;
        }

        Logger.warning(
            'HLS segment fetch error ($attempt/$maxRetryAttempts) for $uri: $e');
        Logger.debug('$stackTrace');
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    throw Exception('HLS segment fetch cancelled for $uri');
  }
}

class _ParsedHlsPlaylist {
  final int mediaSequence;
  final List<_HlsSegment> segments;
  final Duration? targetDuration;
  final Duration totalDuration;

  _ParsedHlsPlaylist({
    required this.mediaSequence,
    required this.segments,
    required this.targetDuration,
    required this.totalDuration,
  });

  factory _ParsedHlsPlaylist.parse(Uri playlistUri, String body) {
    final lines = const LineSplitter().convert(body);
    final segments = <_HlsSegment>[];
    int mediaSequence = 0;
    Duration? targetDuration;
    Duration? currentDuration;
    var nextSequence = 0;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXT-X-MEDIA-SEQUENCE')) {
        final parts = line.split(':');
        if (parts.length == 2) {
          final parsed = int.tryParse(parts.last.trim());
          if (parsed != null) {
            mediaSequence = parsed;
            nextSequence = parsed;
          }
        }
      } else if (line.startsWith('#EXT-X-TARGETDURATION')) {
        final parts = line.split(':');
        if (parts.length == 2) {
          final parsed = int.tryParse(parts.last.trim());
          if (parsed != null) {
            targetDuration = Duration(seconds: parsed);
          }
        }
      } else if (line.startsWith('#EXTINF')) {
        final value = line.split(':').last.split(',').first.trim();
        final seconds = double.tryParse(value);
        if (seconds != null) {
          currentDuration = Duration(milliseconds: (seconds * 1000).round());
        }
      } else if (!line.startsWith('#')) {
        final segmentUri = playlistUri.resolve(line);
        final sequence = nextSequence;
        nextSequence++;
        segments.add(
          _HlsSegment(
            sequence: sequence,
            uri: segmentUri,
            duration: currentDuration ?? targetDuration ?? Duration.zero,
          ),
        );
        currentDuration = null;
      }
    }

    final totalDuration = segments.fold<Duration>(
        Duration.zero, (sum, segment) => sum + segment.duration);

    return _ParsedHlsPlaylist(
      mediaSequence: mediaSequence,
      segments: segments,
      targetDuration: targetDuration,
      totalDuration: totalDuration,
    );
  }
}

class _HlsSegment {
  final int sequence;
  final Uri uri;
  final Duration duration;

  _HlsSegment({
    required this.sequence,
    required this.uri,
    required this.duration,
  });
}
