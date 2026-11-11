import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/core/audio_state.dart';
import 'package:tunio_radio_player/models/stream_config.dart';
import 'package:tunio_radio_player/services/radio/enhanced_radio_service.dart';

void main() {
  const live = StreamConfig(streamUrl: 'https://example.com/live.aac');
  const screenOnly = StreamConfig(streamUrl: '');

  RadioState connected(AudioState audio, [StreamConfig config = live]) =>
      RadioStateConnected(token: '123456', config: config, audioState: audio);

  test('a point sounds while its stream plays or is about to', () {
    expect(
        EnhancedRadioService.soundsAt(
            connected(const AudioStatePlaying(config: live))),
        isTrue);
    expect(
        EnhancedRadioService.soundsAt(
            connected(const AudioStateLoading(config: live))),
        isTrue);
  });

  test('stopped, paused or not connected is silence', () {
    expect(
        EnhancedRadioService.soundsAt(
            connected(const AudioStatePaused(config: live))),
        isFalse);
    expect(EnhancedRadioService.soundsAt(connected(const AudioStateIdle())),
        isFalse);
    expect(
        EnhancedRadioService.soundsAt(const RadioStateDisconnected()), isFalse);
  });

  test('the offline cache playing counts as sound', () {
    expect(
        EnhancedRadioService.soundsAt(const RadioStateFailover(
            token: '123456',
            originalConfig: live,
            audioState: AudioStatePlaying(config: live),
            currentTrackPath: '/cache/track.m4a')),
        isTrue);
  });

  test('a screen-only point reports nothing', () {
    expect(
        EnhancedRadioService.soundsAt(
            connected(const AudioStateIdle(), screenOnly)),
        isNull);
  });
}
