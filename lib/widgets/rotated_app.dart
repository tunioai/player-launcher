import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/screen_rotation.dart';

/// Turns the whole interface by [ScreenRotation] and keeps it usable that way:
/// layouts see the turned size, and the remote's arrows move focus the way
/// they look on the turned picture rather than along the panel's own axes.
class RotatedApp extends StatelessWidget {
  final Widget child;

  const RotatedApp({super.key, required this.child});

  static const List<TraversalDirection> _clockwise = [
    TraversalDirection.up,
    TraversalDirection.right,
    TraversalDirection.down,
    TraversalDirection.left,
  ];

  static final List<(LogicalKeyboardKey, TraversalDirection)> _arrows = [
    (LogicalKeyboardKey.arrowUp, TraversalDirection.up),
    (LogicalKeyboardKey.arrowRight, TraversalDirection.right),
    (LogicalKeyboardKey.arrowDown, TraversalDirection.down),
    (LogicalKeyboardKey.arrowLeft, TraversalDirection.left),
  ];

  static TraversalDirection _onPanel(
      TraversalDirection direction, int quarterTurns) {
    return _clockwise[(_clockwise.indexOf(direction) + quarterTurns) % 4];
  }

  static EdgeInsets _turn(EdgeInsets insets, int quarterTurns) {
    var turned = insets;
    for (var i = 0; i < quarterTurns; i++) {
      turned = EdgeInsets.fromLTRB(
          turned.top, turned.right, turned.bottom, turned.left);
    }
    return turned;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ScreenRotation.degrees,
      builder: (context, degrees, _) {
        final quarterTurns = degrees ~/ 90;
        if (quarterTurns == 0) return child;

        final media = MediaQuery.of(context);
        final sideways = quarterTurns.isOdd;
        return MediaQuery(
          data: media.copyWith(
            size: sideways ? media.size.flipped : media.size,
            padding: _turn(media.padding, quarterTurns),
            viewPadding: _turn(media.viewPadding, quarterTurns),
            viewInsets: _turn(media.viewInsets, quarterTurns),
          ),
          child: Shortcuts(
            shortcuts: {
              for (final (key, direction) in _arrows)
                SingleActivator(key):
                    DirectionalFocusIntent(_onPanel(direction, quarterTurns)),
            },
            child: RotatedBox(quarterTurns: quarterTurns, child: child),
          ),
        );
      },
    );
  }
}
