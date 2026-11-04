import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/radio/failover_recovery_backoff.dart';

void main() {
  final start = DateTime(2026, 11, 4, 12);

  test('forced restores are spaced out, doubling up to ten minutes', () {
    final backoff = FailoverRecoveryBackoff();
    var now = start;
    final gaps = <int>[];
    for (var i = 0; i < 6; i++) {
      expect(backoff.forcedRestoreDue(now), isTrue);
      backoff.recordForcedRestore(now);
      var next = now.add(const Duration(seconds: 1));
      while (!backoff.forcedRestoreDue(next)) {
        next = next.add(const Duration(seconds: 1));
      }
      gaps.add(next.difference(now).inSeconds);
      now = next;
    }
    expect(gaps, [60, 120, 240, 480, 600, 600]);
  });

  test('a successful restore lets the next forced one come at once', () {
    final backoff = FailoverRecoveryBackoff();
    backoff.recordForcedRestore(start);
    backoff.recordForcedRestore(start);
    expect(backoff.forcedRestoreDue(start.add(const Duration(seconds: 30))),
        isFalse);
    backoff.recordSuccessfulRestore();
    expect(backoff.forcedRestoreDue(start), isTrue);
    backoff.recordForcedRestore(start);
    expect(backoff.forcedRestoreDue(start.add(const Duration(seconds: 60))),
        isTrue);
  });
}
