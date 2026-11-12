import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/models/stream_config.dart';

void main() {
  group('StreamConfig screen rotation', () {
    test('reads a quarter turn from the payload', () {
      final config = StreamConfig.fromJson({
        'stream_url': 'https://example.com/live',
        'screen_rotation': 270,
      });
      expect(config.screenRotation, 270);
    });

    test('falls back to upright for missing or unsupported values', () {
      expect(StreamConfig.fromJson({'stream_url': ''}).screenRotation, 0);
      expect(
        StreamConfig.fromJson({'stream_url': '', 'screen_rotation': 45})
            .screenRotation,
        0,
      );
    });

    test('survives the cached round trip', () {
      final config = StreamConfig.fromJson({
        'stream_url': 'https://example.com/live',
        'screen_rotation': 90,
      });
      expect(StreamConfig.fromJson(config.toJson()), config);
    });

    test('a rotation change alone is a config change', () {
      const upright = StreamConfig(streamUrl: 'https://example.com/live');
      const sideways = StreamConfig(
        streamUrl: 'https://example.com/live',
        screenRotation: 90,
      );
      expect(upright == sideways, isFalse);
    });
  });

  group('StreamConfig covers', () {
    test('reads the station cover and the track artwork', () {
      final config = StreamConfig.fromJson({
        'stream_url': 'https://example.com/live',
        'image_url': 'https://cdn3.tunio.ai/covers/station.jpg',
        'current': {
          'artist': 'Nora Vale',
          'title': 'Morning Breeze',
          'uuid': 'song-1',
          'is_music': true,
          'artwork_url': 'https://cdn3.tunio.ai/music_posters/song-1.jpg',
        },
      });
      expect(config.imageUrl, 'https://cdn3.tunio.ai/covers/station.jpg');
      expect(config.current?.artworkUrl,
          'https://cdn3.tunio.ai/music_posters/song-1.jpg');
    });

    test('missing covers stay null and survive the cached round trip', () {
      final config = StreamConfig.fromJson({
        'stream_url': 'https://example.com/live',
        'current': {'uuid': 'song-1', 'artwork_url': ''},
      });
      expect(config.imageUrl, isNull);
      expect(config.current?.artworkUrl, isNull);

      final covered = StreamConfig.fromJson({
        'stream_url': 'https://example.com/live',
        'image_url': 'https://cdn3.tunio.ai/covers/station.jpg',
        'current': {
          'uuid': 'song-1',
          'artwork_url': 'https://cdn3.tunio.ai/music_posters/song-1.jpg',
        },
      });
      final restored = StreamConfig.fromJson(covered.toJson());
      expect(restored, covered);
      expect(restored.imageUrl, covered.imageUrl);
      expect(restored.current?.artworkUrl, covered.current?.artworkUrl);
    });
  });
}
