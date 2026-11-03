import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/live_stall.dart';

void main() {
  const threshold = Duration(seconds: 60);

  test('a silent buffer is no stall while the position moves', () {
    expect(
      isLiveBufferStalled(
        sinceBufferUpdate: const Duration(minutes: 30),
        sincePlaybackProgress: const Duration(seconds: 1),
        threshold: threshold,
      ),
      isFalse,
    );
  });

  test('buffer and position both frozen is a stall', () {
    expect(
      isLiveBufferStalled(
        sinceBufferUpdate: const Duration(seconds: 61),
        sincePlaybackProgress: const Duration(seconds: 61),
        threshold: threshold,
      ),
      isTrue,
    );
  });

  test('a frozen buffer with no progress ever seen is a stall', () {
    expect(
      isLiveBufferStalled(
        sinceBufferUpdate: const Duration(seconds: 61),
        sincePlaybackProgress: null,
        threshold: threshold,
      ),
      isTrue,
    );
  });

  test('a fresh buffer is never a stall', () {
    expect(
      isLiveBufferStalled(
        sinceBufferUpdate: const Duration(seconds: 5),
        sincePlaybackProgress: const Duration(minutes: 5),
        threshold: threshold,
      ),
      isFalse,
    );
  });
}
