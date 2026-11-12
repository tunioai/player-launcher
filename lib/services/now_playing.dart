import 'dart:io';

import 'package:audio_service/audio_service.dart';

import '../core/audio_state.dart';
import '../models/current_track.dart';
import '../models/stream_config.dart';
import '../utils/logger.dart';
import 'radio/i_radio_service.dart';

typedef CachedTrackLookup = Future<CurrentTrack?> Function(String trackPath);

/// The system media controls -- the Android notification and lock screen, the
/// iOS Lock Screen and Control Center, headset and Bluetooth buttons.
///
/// On Android this is also the media-playback foreground service that keeps
/// the process, and with it background failover, alive with the screen off.
/// Windows and macOS have no such service and play through just_audio alone.
class NowPlaying {
  static bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// Never throws: without the service the point still plays, it only loses
  /// the system controls (and on Android the foreground service).
  static Future<void> start({
    required IRadioService radioService,
    required CachedTrackLookup cachedTrack,
  }) async {
    if (!isSupported) return;
    try {
      await AudioService.init(
        builder: () => NowPlayingHandler(
          radioService: radioService,
          cachedTrack: cachedTrack,
        ),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'ai.tunio.radioplayer.channel.audio',
          androidNotificationChannelName: 'Tunio Radio',
          androidNotificationIcon: 'mipmap/ic_launcher',
          // Ongoing needs androidStopForegroundOnPause, which is the default.
          androidNotificationOngoing: true,
          artDownscaleWidth: 512,
          artDownscaleHeight: 512,
        ),
      );
    } catch (e, stackTrace) {
      Logger.error('Media controls init failed', 'startup', e, stackTrace);
    }
  }
}

/// Mirrors the radio service into the media session and sends the session's
/// commands back through the same radio-service calls the in-app buttons use,
/// so user pause and auto recovery stay in one place.
class NowPlayingHandler extends BaseAudioHandler {
  final IRadioService _radioService;
  final CachedTrackLookup _cachedTrack;
  int _generation = 0;
  String? _cachedTrackPath;
  Future<CurrentTrack?>? _cachedTrackDetails;

  NowPlayingHandler({
    required IRadioService radioService,
    required CachedTrackLookup cachedTrack,
  })  : _radioService = radioService,
        _cachedTrack = cachedTrack {
    radioService.stateStream.listen(_show);
    _show(radioService.currentState);
  }

  @override
  Future<void> play() => _run('play', _radioService.play);

  @override
  Future<void> pause() => _run('pause', _radioService.pause);

  /// A stop from a headset, a car or a swiped-away notification is a request
  /// for silence, not for tearing the session down: the point has to come back
  /// with play.
  @override
  Future<void> stop() => _run('stop', _radioService.pause);

  Future<void> _run(String command, Future<Object?> Function() action) async {
    Logger.info('Media controls: $command', 'NowPlaying');
    try {
      await action();
    } catch (e, stackTrace) {
      Logger.error(
          'Media controls: $command failed', 'NowPlaying', e, stackTrace);
    }
  }

  Future<void> _show(RadioState state) async {
    final generation = ++_generation;
    CurrentTrack? cached;
    if (state is RadioStateFailover) {
      cached = await _cachedTrackAt(state.currentTrackPath);
      if (generation != _generation) return;
    }

    final item = nowPlayingItem(state, cachedTrack: cached);
    if (item != null && !sameNowPlayingItem(item, mediaItem.value)) {
      mediaItem.add(item);
    }

    final next = nowPlayingState(
      state,
      wasPlaying: playbackState.value.playing,
    );
    if (!samePlaybackState(next, playbackState.value)) {
      playbackState.add(next);
    }
  }

  Future<CurrentTrack?> _cachedTrackAt(String path) {
    if (path != _cachedTrackPath || _cachedTrackDetails == null) {
      _cachedTrackPath = path;
      _cachedTrackDetails = _cachedTrack(path);
    }
    return _cachedTrackDetails!;
  }
}

/// What the system media controls show for [state]: the music track on air,
/// or the station while a jingle, an announcement or nothing known is on.
/// Playing from the cache shows the cached track when its details were kept.
MediaItem? nowPlayingItem(RadioState state, {CurrentTrack? cachedTrack}) {
  return switch (state) {
    RadioStateConnected(:final config) when config.hasStream =>
      _trackItem(config, config.current) ?? _stationItem(config),
    RadioStateFailover(:final originalConfig) =>
      _trackItem(originalConfig, cachedTrack) ?? _stationItem(originalConfig),
    _ => null,
  };
}

MediaItem? _trackItem(StreamConfig? station, CurrentTrack? track) {
  if (track == null || !track.isMusic || track.title.trim().isEmpty) {
    return null;
  }
  final artist = track.artist.trim();
  return MediaItem(
    id: 'track:${track.uuid}',
    title: track.title,
    artist: artist.isEmpty ? null : artist,
    album: _nonEmpty(station?.title),
    artUri: _uri(track.artworkUrl) ?? _uri(station?.imageUrl),
    isLive: true,
  );
}

MediaItem _stationItem(StreamConfig? station) {
  return MediaItem(
    id: 'station:${station?.streamUuid ?? station?.streamUrl ?? ''}',
    title: _nonEmpty(station?.title) ?? 'Tunio Spot',
    artist: _nonEmpty(station?.description),
    artUri: _uri(station?.imageUrl),
    isLive: true,
  );
}

/// MediaItem equality is by id alone; the station item keeps its id while its
/// title, description or cover change.
bool sameNowPlayingItem(MediaItem a, MediaItem? b) {
  return b != null &&
      a.id == b.id &&
      a.title == b.title &&
      a.artist == b.artist &&
      a.album == b.album &&
      a.artUri == b.artUri;
}

/// The session state for [state].
///
/// `playing` is whether the point means to sound, not whether a frame is
/// coming out this instant: a stream restart, a failover track switch or a
/// retry keeps the last value. On Android, `playing` going false takes the
/// service out of the foreground and idle stops it, and bringing it back from
/// the background is not always allowed -- a recovery must not drop it.
PlaybackState nowPlayingState(RadioState state, {required bool wasPlaying}) {
  final (processing, playing) = switch (state) {
    RadioStateConnected(:final config) when !config.hasStream => (
        AudioProcessingState.idle,
        false
      ),
    RadioStateConnected(:final audioState) ||
    RadioStateFailover(:final audioState) =>
      _fromAudio(audioState, wasPlaying),
    RadioStateConnecting() => (AudioProcessingState.loading, wasPlaying),
    RadioStateError(:final canRetry) => canRetry
        ? (AudioProcessingState.loading, wasPlaying)
        : (AudioProcessingState.error, false),
    RadioStateDisconnected() => (AudioProcessingState.idle, false),
  };

  final controllable = processing != AudioProcessingState.idle &&
      !(state.config?.paused ?? false);
  final controls = controllable
      ? [playing ? MediaControl.pause : MediaControl.play]
      : const <MediaControl>[];

  return PlaybackState(
    processingState: processing,
    playing: playing,
    controls: controls,
    androidCompactActionIndices: controls.isEmpty ? null : const [0],
  );
}

(AudioProcessingState, bool) _fromAudio(AudioState audio, bool wasPlaying) {
  return switch (audio) {
    AudioStatePlaying() => (AudioProcessingState.ready, true),
    AudioStateLoading() => (AudioProcessingState.loading, true),
    AudioStateBuffering() => (AudioProcessingState.buffering, true),
    AudioStatePaused() => (AudioProcessingState.ready, false),
    AudioStateError() => (AudioProcessingState.buffering, wasPlaying),
    AudioStateIdle() => (AudioProcessingState.loading, wasPlaying),
  };
}

bool samePlaybackState(PlaybackState a, PlaybackState b) {
  return a.processingState == b.processingState &&
      a.playing == b.playing &&
      _sameControls(a.controls, b.controls);
}

bool _sameControls(List<MediaControl> a, List<MediaControl> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].action != b[i].action) return false;
  }
  return true;
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

Uri? _uri(String? value) {
  final text = _nonEmpty(value);
  if (text == null) return null;
  final uri = Uri.tryParse(text);
  return uri != null && uri.hasScheme ? uri : null;
}
