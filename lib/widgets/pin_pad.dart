import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart' show TunioColors;

/// Digits-only PIN entry, in place of the system keyboard on every platform:
/// part of the interface, so it turns with a rotated screen (the system
/// keyboard does not), the remote moves over it, and it needs no return key
/// (an iPhone number pad has none). Number keys of a remote or keyboard type
/// directly; Back closes it. Pops the code once all digits are in.
class PinPad extends StatefulWidget {
  final String initial;
  final int length;

  const PinPad({super.key, this.initial = '', this.length = 6});

  static Future<String?> show(BuildContext context,
      {String initial = '', int length = 6}) {
    return showDialog<String>(
      context: context,
      builder: (_) => PinPad(initial: initial, length: length),
    );
  }

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  late String _code;

  static final Map<LogicalKeyboardKey, String> _digitKeys = {
    for (var d = 0; d <= 9; d++) ...{
      LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d): '$d',
      LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + d): '$d',
    },
  };

  @override
  void initState() {
    super.initState();
    _code = widget.initial.length < widget.length ? widget.initial : '';
  }

  void _type(String digit) {
    if (_code.length >= widget.length) return;
    setState(() => _code += digit);
    if (_code.length == widget.length) Navigator.of(context).pop(_code);
  }

  void _erase() {
    if (_code.isEmpty) return;
    setState(() => _code = _code.substring(0, _code.length - 1));
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final digit = _digitKeys[event.logicalKey];
    if (digit != null) {
      _type(digit);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace ||
        event.logicalKey == LogicalKeyboardKey.delete) {
      _erase();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _key(Widget label, VoidCallback? onPressed, {bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: SizedBox(
        width: 72,
        height: 56,
        child: ElevatedButton(
          autofocus: autofocus,
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.zero,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ).copyWith(
            side: WidgetStateProperty.resolveWith((states) =>
                states.contains(WidgetState.focused)
                    ? const BorderSide(color: TunioColors.accent, width: 3)
                    : null),
          ),
          child: label,
        ),
      ),
    );
  }

  Widget _digit(String d, {bool autofocus = false}) => _key(
      Text(d,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
      () => _type(d),
      autofocus: autofocus);

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter 6-digit code',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.length; i++)
                    Container(
                      width: 36,
                      height: 44,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: i == _code.length
                              ? TunioColors.accent
                              : Colors.grey,
                          width: i == _code.length ? 2 : 1,
                        ),
                      ),
                      child: Text(i < _code.length ? _code[i] : '',
                          style: const TextStyle(
                              fontSize: 22, fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              for (final row in const [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
              ])
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final d in row) _digit(d, autofocus: d == '1'),
                  ],
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _key(const Icon(Icons.backspace_outlined),
                      _code.isEmpty ? null : _erase),
                  _digit('0'),
                  _key(const Icon(Icons.close),
                      () => Navigator.of(context).pop()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
