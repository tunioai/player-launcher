import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/core/audio_state.dart';
import 'package:tunio_radio_player/core/result.dart';
import 'package:tunio_radio_player/models/current_track.dart';
import 'package:tunio_radio_player/models/stream_config.dart';
import 'package:tunio_radio_player/services/now_playing.dart';
import 'package:tunio_radio_player/services/radio/i_radio_service.dart';

const _song = CurrentTrack(
  artist: 'Nora Vale',
  title: 'Morning Breeze',
  uuid: 'song-1',
  duration: 184,
  isMusic: true,
  url: 'https://cdn.example.com/song-1.m4a',
  artworkUrl: 'https://cdn3.tunio.ai/music_posters/song-1.jpg',
);

const _jingle = CurrentTrack(
  artist: '',
  title: 'Station ID',
  uuid: 'jingle-1',
  duration: 6,
  isMusic: false,
  url: '',
  artworkUrl: 'https://cdn3.tunio.ai/covers/station.jpg',
);

const _station = StreamConfig(
  streamUrl: 'https://example.com/live.aac',
  streamUuid: 'station-1',
  title: 'Cafe Aurora',
  description: 'Morning mix',
  imageUrl: 'https://cdn3.tunio.ai/covers/station.jpg',
);

StreamConfig _withCurrent(CurrentTrack? current, {bool paused = false}) =>
    StreamConfig(
      streamUrl: _station.streamUrl,
      streamUuid: _station.streamUuid,
      title: _station.title,
      description: _station.description,
      imageUrl: _station.imageUrl,
      current: current,
      paused: paused,
    );

RadioState _connected(StreamConfig config,
        {AudioState audio = const AudioStatePlaying(config: _station)}) =>
    RadioStateConnected(token: '112233', config: config, audioState: audio);

RadioState _failover(String path) => RadioStateFailover(
      token: '112233',
      originalConfig: _withCurrent(_song),
      audioState: const AudioStatePlaying(config: _station),
      currentTrackPath: path,
    );

void main() {
  group('nowPlayingItem', () {
    test('a music track shows its title, artist and cover', () {
      final item = nowPlayingItem(_connected(_withCurrent(_song)))!;
      expect(item.title, 'Morning Breeze');
      expect(item.artist, 'Nora Vale');
      expect(item.album, 'Cafe Aurora');
      expect(item.artUri, Uri.parse(_song.artworkUrl!));
      expect(item.isLive, isTrue);
    });

    test('a track without its own cover falls back to the station cover', () {
      const bare = CurrentTrack(
        artist: 'Nora Vale',
        title: 'Evening',
        uuid: 'song-2',
        duration: 200,
        isMusic: true,
        url: '',
      );
      final item = nowPlayingItem(_connected(_withCurrent(bare)))!;
      expect(item.title, 'Evening');
      expect(item.artUri, Uri.parse(_station.imageUrl!));
    });

    test('a jingle or announcement shows the station', () {
      final item = nowPlayingItem(_connected(_withCurrent(_jingle)))!;
      expect(item.title, 'Cafe Aurora');
      expect(item.artist, 'Morning mix');
      expect(item.artUri, Uri.parse(_station.imageUrl!));
    });

    test('nothing known on air shows the station, without art if it has none',
        () {
      const plain = StreamConfig(
        streamUrl: 'https://example.com/live.aac',
        title: 'Cafe Aurora',
      );
      final item = nowPlayingItem(_connected(plain))!;
      expect(item.title, 'Cafe Aurora');
      expect(item.artist, isNull);
      expect(item.artUri, isNull);
    });

    test('a new track on air changes the item', () {
      final first = nowPlayingItem(_connected(_withCurrent(_jingle)))!;
      final second = nowPlayingItem(_connected(_withCurrent(_song)))!;
      expect(sameNowPlayingItem(second, first), isFalse);
      expect(
        sameNowPlayingItem(
            second, nowPlayingItem(_connected(_withCurrent(_song)))),
        isTrue,
      );
    });

    test('playing from the cache shows the cached track, not the live one', () {
      const cached = CurrentTrack(
        artist: 'Kai Moreno',
        title: 'Tidewater',
        uuid: 'song-9',
        duration: 210,
        isMusic: true,
        url: '',
        artworkUrl: 'https://cdn3.tunio.ai/music_posters/song-9.jpg',
      );
      final item =
          nowPlayingItem(_failover('/cache/song-9.m4a'), cachedTrack: cached)!;
      expect(item.title, 'Tidewater');
      expect(item.artist, 'Kai Moreno');
    });

    test('a cached file with no details shows the station', () {
      final item = nowPlayingItem(_failover('/cache/old.m4a'))!;
      expect(item.title, 'Cafe Aurora');
      expect(item.artist, 'Morning mix');
    });

    test('a screen-only point and a disconnected one have nothing to show', () {
      const screenOnly = StreamConfig(streamUrl: '', title: 'Lobby');
      expect(nowPlayingItem(_connected(screenOnly)), isNull);
      expect(nowPlayingItem(const RadioStateDisconnected()), isNull);
    });
  });

  group('nowPlayingState', () {
    test('playing offers pause and no seeking', () {
      final state = nowPlayingState(_connected(_station), wasPlaying: false);
      expect(state.playing, isTrue);
      expect(state.processingState, AudioProcessingState.ready);
      expect(state.controls.map((c) => c.action), [MediaAction.pause]);
      expect(state.systemActions, isEmpty);
    });

    test('a pause offers play', () {
      final state = nowPlayingState(
        _connected(_station,
            audio: const AudioStatePaused(
                config: _station, position: Duration(seconds: 4))),
        wasPlaying: true,
      );
      expect(state.playing, isFalse);
      expect(state.controls.map((c) => c.action), [MediaAction.play]);
    });

    test('recovery keeps the session playing so the service stays up', () {
      final error = nowPlayingState(
        _connected(_station,
            audio: const AudioStateError(message: 'Network error')),
        wasPlaying: true,
      );
      expect(error.playing, isTrue);
      expect(error.processingState, AudioProcessingState.buffering);

      final switching = nowPlayingState(
        _connected(_station, audio: const AudioStateIdle()),
        wasPlaying: true,
      );
      expect(switching.playing, isTrue);
      expect(switching.processingState, isNot(AudioProcessingState.idle));

      final retry = nowPlayingState(
        const RadioStateConnecting(token: '112233'),
        wasPlaying: true,
      );
      expect(retry.playing, isTrue);
    });

    test('a zone paused from the control panel offers no controls', () {
      final state = nowPlayingState(
        _connected(_withCurrent(null, paused: true),
            audio: const AudioStatePaused(
                config: _station, position: Duration(seconds: 4))),
        wasPlaying: true,
      );
      expect(state.playing, isFalse);
      expect(state.controls, isEmpty);
    });

    test('disconnected and screen-only end the session', () {
      expect(
        nowPlayingState(const RadioStateDisconnected(), wasPlaying: true)
            .processingState,
        AudioProcessingState.idle,
      );
      expect(
        nowPlayingState(_connected(const StreamConfig(streamUrl: '')),
                wasPlaying: true)
            .processingState,
        AudioProcessingState.idle,
      );
    });

    test('a connection that cannot be retried shows an error', () {
      final state = nowPlayingState(
        const RadioStateError(message: 'Invalid PIN', canRetry: false),
        wasPlaying: true,
      );
      expect(state.playing, isFalse);
      expect(state.processingState, AudioProcessingState.error);
    });
  });

  group('NowPlayingHandler', () {
    test('system play, pause, stop and headset go through the radio service',
        () async {
      final radio = _FakeRadioService(_connected(_withCurrent(_song)));
      final handler = NowPlayingHandler(
        radioService: radio,
        cachedTrack: (_) async => null,
      );
      await pumpEventQueue();

      await handler.pause();
      await handler.stop();
      await handler.play();
      expect(radio.calls, ['pause', 'pause', 'play']);

      radio.calls.clear();
      await handler.click();
      expect(radio.calls, ['pause']);
      await radio.close();
    });

    test('a new track updates the item without touching playback', () async {
      final radio = _FakeRadioService(_connected(_withCurrent(_jingle)));
      final handler = NowPlayingHandler(
        radioService: radio,
        cachedTrack: (_) async => null,
      );
      await pumpEventQueue();
      expect(handler.mediaItem.value?.title, 'Cafe Aurora');
      expect(handler.playbackState.value.playing, isTrue);

      radio.emit(_connected(_withCurrent(_song)));
      await pumpEventQueue();
      expect(handler.mediaItem.value?.title, 'Morning Breeze');
      expect(handler.mediaItem.value?.artUri, Uri.parse(_song.artworkUrl!));
      expect(radio.calls, isEmpty);
      await radio.close();
    });

    test('playing from the cache looks the track up once per file', () async {
      final lookups = <String>[];
      const cached = CurrentTrack(
        artist: 'Kai Moreno',
        title: 'Tidewater',
        uuid: 'song-9',
        duration: 210,
        isMusic: true,
        url: '',
      );
      final radio = _FakeRadioService(const RadioStateDisconnected());
      final handler = NowPlayingHandler(
        radioService: radio,
        cachedTrack: (path) async {
          lookups.add(path);
          return cached;
        },
      );

      radio.emit(_failover('/cache/song-9.m4a'));
      radio.emit(_failover('/cache/song-9.m4a'));
      await pumpEventQueue();
      expect(handler.mediaItem.value?.title, 'Tidewater');
      expect(lookups, ['/cache/song-9.m4a']);
      await radio.close();
    });
  });
}

class _FakeRadioService implements IRadioService {
  final StreamController<RadioState> _states =
      StreamController<RadioState>.broadcast();
  final List<String> calls = [];
  RadioState _current;

  _FakeRadioService(this._current);

  void emit(RadioState state) {
    _current = state;
    _states.add(state);
  }

  Future<void> close() => _states.close();

  @override
  Stream<RadioState> get stateStream => _states.stream;

  @override
  RadioState get currentState => _current;

  @override
  Future<Result<void>> pause() async {
    calls.add('pause');
    return const Success(null);
  }

  @override
  Future<Result<void>> play() async {
    calls.add('play');
    return const Success(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
