import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunio_radio_player/services/screen_rotation.dart';
import 'package:tunio_radio_player/services/storage_service.dart';
import 'package:tunio_radio_player/widgets/rotated_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final storage = await StorageService.getInstance();
    await storage.clear();
  });

  test('the link takes over from a local turn without undoing it by default',
      () async {
    await ScreenRotation.rotateClockwise();
    expect(ScreenRotation.degrees.value, 90);

    await ScreenRotation.applyLinked(0);
    expect(ScreenRotation.degrees.value, 90,
        reason: 'a link left upright must not undo the installer\'s turn');

    await ScreenRotation.applyLinked(270);
    expect(ScreenRotation.degrees.value, 270);

    await ScreenRotation.applyLinked(0);
    expect(ScreenRotation.degrees.value, 0,
        reason: 'setting the link back to upright is a real choice');

    final storage = await StorageService.getInstance();
    expect(storage.screenRotation(), 0);
  });

  for (final degrees in ScreenRotation.supported) {
    testWidgets('down on the remote moves down the picture at $degrees°',
        (tester) async {
      final top = FocusNode();
      final middle = FocusNode();
      final bottom = FocusNode();
      ScreenRotation.degrees.value = degrees;
      addTearDown(() {
        ScreenRotation.degrees.value = 0;
        top.dispose();
        middle.dispose();
        bottom.dispose();
      });

      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => RotatedApp(child: child!),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Focus(
                    focusNode: top,
                    child: const SizedBox(width: 120, height: 60)),
                const SizedBox(height: 40),
                Focus(
                  focusNode: middle,
                  child: const SizedBox(width: 120, height: 60),
                ),
                const SizedBox(height: 40),
                Focus(
                    focusNode: bottom,
                    child: const SizedBox(width: 120, height: 60)),
              ],
            ),
          ),
        ),
      ));

      middle.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(bottom.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(middle.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(top.hasFocus, isTrue);
    });
  }
}
