import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class CodeInputWidget extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final bool enabled;
  final FocusNode? focusNode;

  const CodeInputWidget({
    super.key,
    required this.value,
    required this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.focusNode,
  });

  @override
  State<CodeInputWidget> createState() => _CodeInputWidgetState();
}

class _CodeInputWidgetState extends State<CodeInputWidget> {
  final int _codeLength = 6;
  late List<String> _digits;
  late FocusNode _focusNode;
  late TextEditingController _textController;

  // Detect if we're on mobile platform
  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _textController = TextEditingController();
    _updateDigitsFromValue();
  }

  @override
  void dispose() {
    _textController.dispose();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _updateDigitsFromValue() {
    _digits = List.filled(_codeLength, '');
    final value = widget.value.replaceAll(RegExp(r'\D'), '');
    for (int i = 0; i < value.length && i < _codeLength; i++) {
      _digits[i] = value[i];
    }
    _textController.text = value;
  }

  @override
  void didUpdateWidget(CodeInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _updateDigitsFromValue();
    }
  }

  void _updateCode() {
    final code = _digits.join('');
    widget.onChanged(code);

    if (code.length == _codeLength) {
      widget.onSubmitted?.call();
    }
  }

  void _onTextChanged(String text) {
    if (!widget.enabled) return;

    // Only keep digits
    final cleanText = text.replaceAll(RegExp(r'\D'), '');

    if (cleanText.length <= _codeLength) {
      setState(() {
        _digits = List.filled(_codeLength, '');
        for (int i = 0; i < cleanText.length; i++) {
          _digits[i] = cleanText[i];
        }
      });

      widget.onChanged(cleanText);

      if (cleanText.length == _codeLength) {
        widget.onSubmitted?.call();
      }
    } else {
      // Prevent input beyond 6 digits
      _textController.text = cleanText.substring(0, _codeLength);
      _textController.selection = TextSelection.fromPosition(
        TextPosition(offset: _codeLength),
      );
    }
  }

  void _addDigit(String digit) {
    if (!widget.enabled) return;

    for (int i = 0; i < _codeLength; i++) {
      if (_digits[i].isEmpty) {
        setState(() {
          _digits[i] = digit;
        });
        _updateCode();
        break;
      }
    }
  }

  void _removeLastDigit() {
    if (!widget.enabled) return;

    for (int i = _codeLength - 1; i >= 0; i--) {
      if (_digits[i].isNotEmpty) {
        setState(() {
          _digits[i] = '';
        });
        _updateCode();
        break;
      }
    }
  }

  void _clearAll() {
    if (!widget.enabled) return;

    setState(() {
      _digits = List.filled(_codeLength, '');
    });
    _updateCode();
  }

  Widget _buildMobileInput() {
    return Column(
      children: [
        Text(
          'Enter 6-digit code',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: widget.enabled ? null : Colors.grey,
          ),
        ),
        const SizedBox(height: 16),
        // Visual representation of digits
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(_codeLength, (index) {
            return Container(
              width: 40,
              height: 50,
              decoration: BoxDecoration(
                border: Border.all(
                  color: _digits[index].isNotEmpty
                      ? (_focusNode.hasFocus ? Colors.blue : Colors.grey[600]!)
                      : Colors.grey[300]!,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
                color: _digits[index].isNotEmpty
                    ? (_focusNode.hasFocus
                        ? Colors.blue.withOpacity(0.1)
                        : Colors.grey[50])
                    : Colors.white,
              ),
              child: Center(
                child: Text(
                  _digits[index],
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: widget.enabled
                        ? (_digits[index].isNotEmpty
                            ? Colors.black
                            : Colors.grey[400])
                        : Colors.grey,
                  ),
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 16),
        // Hidden TextField for mobile input
        SizedBox(
          height: 0,
          child: TextField(
            controller: _textController,
            focusNode: _focusNode,
            enabled: widget.enabled,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(_codeLength),
            ],
            onChanged: _onTextChanged,
            onSubmitted: (_) {
              if (_digits.join('').length == _codeLength) {
                widget.onSubmitted?.call();
              }
            },
            decoration: const InputDecoration(
              border: InputBorder.none,
            ),
            style: const TextStyle(color: Colors.transparent),
            cursorColor: Colors.transparent,
            showCursor: false,
          ),
        ),
        GestureDetector(
          onTap: widget.enabled ? () => _focusNode.requestFocus() : null,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border.all(
                color: _focusNode.hasFocus ? Colors.blue : Colors.grey[300]!,
                width: 2,
              ),
              borderRadius: BorderRadius.circular(8),
              color: widget.enabled
                  ? Colors.blue.withOpacity(0.05)
                  : Colors.grey[100],
            ),
            child: Text(
              'Tap to enter code',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: widget.enabled ? Colors.blue[700] : Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopInput() {
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final key = event.logicalKey;

          if (key.keyId >= LogicalKeyboardKey.digit0.keyId &&
              key.keyId <= LogicalKeyboardKey.digit9.keyId) {
            final digit =
                (key.keyId - LogicalKeyboardKey.digit0.keyId).toString();
            _addDigit(digit);
            return KeyEventResult.handled;
          } else if (key.keyId >= LogicalKeyboardKey.numpad0.keyId &&
              key.keyId <= LogicalKeyboardKey.numpad9.keyId) {
            final digit =
                (key.keyId - LogicalKeyboardKey.numpad0.keyId).toString();
            _addDigit(digit);
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.backspace) {
            _removeLastDigit();
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.delete ||
              key == LogicalKeyboardKey.escape) {
            _clearAll();
            return KeyEventResult.handled;
          } else if (key == LogicalKeyboardKey.enter ||
              key == LogicalKeyboardKey.select) {
            if (_digits.join('').length == _codeLength) {
              widget.onSubmitted?.call();
            }
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: _focusNode.hasFocus ? Colors.blue : Colors.grey,
            width: _focusNode.hasFocus ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(
              'Enter 6-digit code',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: widget.enabled ? null : Colors.grey,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(_codeLength, (index) {
                return Container(
                  width: 40,
                  height: 50,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _digits[index].isNotEmpty
                          ? (_focusNode.hasFocus
                              ? Colors.blue
                              : Colors.grey[600]!)
                          : Colors.grey[300]!,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                    color: _digits[index].isNotEmpty
                        ? (_focusNode.hasFocus
                            ? Colors.blue.withOpacity(0.1)
                            : Colors.grey[50])
                        : Colors.white,
                  ),
                  child: Center(
                    child: Text(
                      _digits[index],
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: widget.enabled
                            ? (_digits[index].isNotEmpty
                                ? Colors.black
                                : Colors.grey[400])
                            : Colors.grey,
                      ),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 12),
            Text(
              _isMobile
                  ? 'Tap above to enter code'
                  : 'Use remote or keyboard to enter digits',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _isMobile ? _buildMobileInput() : _buildDesktopInput();
  }
}
