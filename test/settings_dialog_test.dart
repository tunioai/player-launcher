import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunio_radio_player/widgets/settings_dialog.dart';

void main() {
  testWidgets('shows the saved startup state and updates it', (tester) async {
    var enabled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsDialog(
            getAutoStartEnabled: () async => enabled,
            setAutoStartEnabled: (value) async {
              enabled = value;
              return enabled;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Start on system boot'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    await tester.tap(find.text('Start on system boot'));
    await tester.pumpAndSettle();

    expect(enabled, isTrue);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('keeps the switch off when enabling startup fails',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsDialog(
            getAutoStartEnabled: () async => false,
            setAutoStartEnabled: (_) async {
              throw Exception('Startup registration failed');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start on system boot'));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.text('Startup registration failed'), findsOneWidget);
  });
}
