// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Basic Widget Tests', () {
    testWidgets('MaterialApp renders correctly', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text('Test App'),
            ),
          ),
        ),
      );

      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.text('Test App'), findsOneWidget);
    });

    testWidgets('Button interaction works', (WidgetTester tester) async {
      int counter = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => counter++,
                child: Text('Counter: $counter'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Counter: 0'), findsOneWidget);
      expect(find.byType(ElevatedButton), findsOneWidget);

      // Tap the button
      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      // Counter should still show 0 as we're not using StatefulWidget
      expect(find.text('Counter: 0'), findsOneWidget);
    });

    testWidgets('CircularProgressIndicator renders',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
