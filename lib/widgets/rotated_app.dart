import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/screen_rotation.dart';

/// Turns the whole interface by [ScreenRotation] and keeps it usable that way:
/// layouts see the turned size, and the remote's arrows move focus the way
/// they look on the turned picture.
///
/// The arrows are not handed to Flutter's directional traversal: inside a
/// [RotatedBox] it measures widgets as inverted rects (left > right), and at
/// 90° and 180° the remote could not leave the player row for the PIN card.
/// Focus moves here instead, by the widgets' places in the unturned layout.
class RotatedApp extends StatefulWidget {
  final Widget child;

  const RotatedApp({super.key, required this.child});

  @override
  State<RotatedApp> createState() => _RotatedAppState();
}

class _RotatedAppState extends State<RotatedApp> {
  final GlobalKey _layoutKey = GlobalKey();

  static final Map<LogicalKeyboardKey, TraversalDirection> _arrows = {
    LogicalKeyboardKey.arrowUp: TraversalDirection.up,
    LogicalKeyboardKey.arrowRight: TraversalDirection.right,
    LogicalKeyboardKey.arrowDown: TraversalDirection.down,
    LogicalKeyboardKey.arrowLeft: TraversalDirection.left,
  };

  static EdgeInsets _turn(EdgeInsets insets, int quarterTurns) {
    var turned = insets;
    for (var i = 0; i < quarterTurns; i++) {
      turned = EdgeInsets.fromLTRB(
          turned.top, turned.right, turned.bottom, turned.left);
    }
    return turned;
  }

  Rect? _layoutRect(FocusNode node, RenderBox layout) {
    final box = node.context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return MatrixUtils.transformRect(
        box.getTransformTo(layout), Offset.zero & box.size);
  }

  void _move(TraversalDirection direction) {
    final current = FocusManager.instance.primaryFocus;
    final layout = _layoutKey.currentContext?.findRenderObject();
    final scope = current?.nearestScope;
    if (current == null || layout is! RenderBox || scope == null) return;
    final from = _layoutRect(current, layout);
    if (from == null) return;

    FocusNode? best;
    var bestScore = double.infinity;
    for (final node in scope.traversalDescendants) {
      if (node == current || !node.canRequestFocus || node.skipTraversal) {
        continue;
      }
      final to = _layoutRect(node, layout);
      if (to == null) continue;
      final score = _score(direction, from, to);
      if (score != null && score < bestScore) {
        bestScore = score;
        best = node;
      }
    }
    if (best == null) return;
    best.requestFocus();
    final target = best.context;
    if (target != null) {
      Scrollable.ensureVisible(target,
          alignment: 0.5, duration: const Duration(milliseconds: 150));
    }
  }

  /// How far [to] is from [from] going [direction]; null when it is not that
  /// way. Widgets sharing the band of [from] across the move come first.
  static double? _score(TraversalDirection direction, Rect from, Rect to) {
    final double gap;
    final double offAxis;
    final bool inBand;
    switch (direction) {
      case TraversalDirection.up:
        if (to.center.dy >= from.center.dy - 1) return null;
        gap = (from.top - to.bottom).clamp(0, double.infinity);
        offAxis = (to.center.dx - from.center.dx).abs();
        inBand = to.left < from.right && to.right > from.left;
      case TraversalDirection.down:
        if (to.center.dy <= from.center.dy + 1) return null;
        gap = (to.top - from.bottom).clamp(0, double.infinity);
        offAxis = (to.center.dx - from.center.dx).abs();
        inBand = to.left < from.right && to.right > from.left;
      case TraversalDirection.left:
        if (to.center.dx >= from.center.dx - 1) return null;
        gap = (from.left - to.right).clamp(0, double.infinity);
        offAxis = (to.center.dy - from.center.dy).abs();
        inBand = to.top < from.bottom && to.bottom > from.top;
      case TraversalDirection.right:
        if (to.center.dx <= from.center.dx + 1) return null;
        gap = (to.left - from.right).clamp(0, double.infinity);
        offAxis = (to.center.dy - from.center.dy).abs();
        inBand = to.top < from.bottom && to.bottom > from.top;
    }
    return (inBand ? 0 : 100000) + gap + offAxis * 2;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ScreenRotation.degrees,
      builder: (context, degrees, _) {
        final quarterTurns = degrees ~/ 90;
        if (quarterTurns == 0) return widget.child;

        final media = MediaQuery.of(context);
        final sideways = quarterTurns.isOdd;
        return MediaQuery(
          data: media.copyWith(
            size: sideways ? media.size.flipped : media.size,
            padding: _turn(media.padding, quarterTurns),
            viewPadding: _turn(media.viewPadding, quarterTurns),
            viewInsets: _turn(media.viewInsets, quarterTurns),
          ),
          child: CallbackShortcuts(
            bindings: {
              for (final entry in _arrows.entries)
                SingleActivator(entry.key): () => _move(entry.value),
            },
            child: RotatedBox(
              quarterTurns: quarterTurns,
              child: KeyedSubtree(key: _layoutKey, child: widget.child),
            ),
          ),
        );
      },
    );
  }
}
