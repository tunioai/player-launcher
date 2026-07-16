import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/utils/audio_config.dart';

void main() {
  test('native HLS profile starts at the default live position (mid-window)',
      () {
    final configuration = AudioConfig.buildUnifiedLoadConfiguration();
    final android = configuration.androidLoadControl;
    final speedControl = configuration.androidLivePlaybackSpeedControl;

    // null → no explicit seek, so ExoPlayer starts ~3×target behind the live
    // edge (the middle of the short window) instead of the trailing edge.
    expect(AudioConfig.hlsInitialPosition, isNull);
    expect(android, isNotNull);
    // Buffer sized to fit inside a ~30s live window (played ~18s behind edge).
    expect(android!.minBufferDuration, const Duration(seconds: 15));
    expect(android.maxBufferDuration, const Duration(seconds: 30));
    expect(android.bufferForPlaybackDuration, const Duration(seconds: 2));
    expect(android.bufferForPlaybackAfterRebufferDuration,
        const Duration(seconds: 4));
    expect(android.prioritizeTimeOverSizeThresholds, isTrue);
    // Live speed control must stay enabled (ExoPlayer defaults, 0.97–1.03) so
    // the player maintains a safe distance from the trailing edge of the
    // window; pinning it to 1.0 disabled that correction.
    expect(speedControl, isNotNull);
    expect(speedControl!.fallbackMinPlaybackSpeed, lessThan(1.0));
    expect(speedControl.fallbackMaxPlaybackSpeed, greaterThan(1.0));
  });
}
