import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/screen_rotation.dart';
import 'package:tunio_radio_player/widgets/rotated_app.dart';

void main() {
  tearDown(() => ScreenRotation.degrees.value = 0);

  for (final degrees in [0, 90, 180, 270]) {
    testWidgets('the remote moves focus as the picture looks at $degrees°',
        (tester) async {
      ScreenRotation.degrees.value = degrees;
      final pin = FocusNode(debugLabel: 'pin');
      final play = FocusNode(debugLabel: 'play');
      final visualizer = FocusNode(debugLabel: 'visualizer');
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => RotatedApp(child: child!),
        home: Scaffold(
          body: Column(children: [
            ElevatedButton(
                focusNode: pin, onPressed: () {}, child: const Text('PIN')),
            const SizedBox(height: 40),
            // The player row is a traversal group, as on the home screen.
            FocusTraversalGroup(
              policy: WidgetOrderTraversalPolicy(),
              child: Row(children: [
                ElevatedButton(
                    focusNode: play,
                    onPressed: () {},
                    child: const Text('Play')),
                IconButton(
                    focusNode: visualizer,
                    onPressed: () {},
                    icon: const Icon(Icons.graphic_eq)),
              ]),
            ),
          ]),
        ),
      ));

      play.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(visualizer.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(pin.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(play.hasFocus || visualizer.hasFocus, isTrue);
    });
  }
}
