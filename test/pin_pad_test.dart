import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/services/screen_rotation.dart';
import 'package:tunio_radio_player/widgets/pin_pad.dart';
import 'package:tunio_radio_player/widgets/rotated_app.dart';

Future<List<String?>> _open(WidgetTester tester) async {
  final results = <String?>[];
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => RotatedApp(child: child!),
    home: Builder(
      builder: (context) => Scaffold(
        body: ElevatedButton(
          onPressed: () async => results.add(await PinPad.show(context)),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

void main() {
  tearDown(() => ScreenRotation.degrees.value = 0);

  testWidgets('remote number keys and buttons type; six digits close it',
      (tester) async {
    final results = await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad3);
    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    for (final d in ['2', '0', '7', '9']) {
      await tester.tap(find.text(d));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(results, ['532079']);
    expect(find.byType(PinPad), findsNothing);
  });

  testWidgets('Back closes it without a code', (tester) async {
    final results = await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('arrows move over the keys on a rotated screen', (tester) async {
    ScreenRotation.degrees.value = 90;
    await _open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final slots = tester.widgetList<Text>(find.descendant(
        of: find.byType(Row).first, matching: find.byType(Text)));
    expect(slots.map((t) => t.data).join(), '5');
  });
}
