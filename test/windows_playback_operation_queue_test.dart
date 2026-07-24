import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/audio/windows_playback_operation_queue.dart';

void main() {
  group('WindowsPlaybackOperationQueue', () {
    test('runs source mutations one at a time in submission order', () async {
      final queue = WindowsPlaybackOperationQueue();
      final firstMayFinish = Completer<void>();
      final events = <String>[];

      final first = queue.run(() async {
        events.add('first-start');
        await firstMayFinish.future;
        events.add('first-end');
        return 1;
      });
      final second = queue.run(() async {
        events.add('second-start');
        events.add('second-end');
        return 2;
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, <String>['first-start']);

      firstMayFinish.complete();
      expect(await first, 1);
      expect(await second, 2);
      expect(events, <String>[
        'first-start',
        'first-end',
        'second-start',
        'second-end',
      ]);
    });

    test('continues with the next mutation after an operation fails', () async {
      final queue = WindowsPlaybackOperationQueue();

      final failed = queue.run<void>(() async {
        throw StateError('load failed');
      });
      final recovered = queue.run(() async => 'recovered');

      await expectLater(failed, throwsStateError);
      expect(await recovered, 'recovered');
    });
  });
}
