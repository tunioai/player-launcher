import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart' show TunioColors;
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

    // Setup focus listener for visual feedback
    _focusNode.addListener(() => setState(() {}));
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
    // Update text controller and position cursor at the end
    if (_textController.text != value) {
      _textController.text = value;
      if (value.isNotEmpty) {
        _textController.selection = TextSelection.fromPosition(
          TextPosition(offset: value.length),
        );
      }
    }
  }

  @override
  void didUpdateWidget(CodeInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _updateDigitsFromValue();
      setState(() {}); // Force UI rebuild to show the updated value
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
                      ? (_focusNode.hasFocus
                          ? TunioColors.primary
                          : Colors.grey[600]!)
                      : (_focusNode.hasFocus
                          ? TunioColors.primary
                          : Colors.grey[300]!),
                  width: _focusNode.hasFocus ? 3 : 2,
                ),
                borderRadius: BorderRadius.circular(8),
                color: _digits[index].isNotEmpty
                    ? (_focusNode.hasFocus
                        ? TunioColors.primary.withValues(alpha: 0.1)
                        : Colors.grey[50])
                    : (_focusNode.hasFocus
                        ? TunioColors.primary.withValues(alpha: 0.05)
                        : Colors.white),
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
                color: _focusNode.hasFocus
                    ? TunioColors.primary
                    : Colors.grey[300]!,
                width: _focusNode.hasFocus ? 3 : 2,
              ),
              borderRadius: BorderRadius.circular(8),
              color: widget.enabled
                  ? (_focusNode.hasFocus
                      ? TunioColors.primary.withValues(alpha: 0.1)
                      : TunioColors.primary.withValues(alpha: 0.05))
                  : Colors.grey[100],
            ),
            child: Text(
              _focusNode.hasFocus
                  ? 'Use remote control or tap to enter code'
                  : 'Tap to enter code',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: widget.enabled
                    ? (_focusNode.hasFocus
                        ? TunioColors.primaryDark
                        : TunioColors.primary)
                    : Colors.grey,
                fontWeight:
                    _focusNode.hasFocus ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDesktopInput() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Column(
        children: [
          Text(
            'Enter 6-digit code',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: widget.enabled ? null : Colors.grey,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
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
            decoration: InputDecoration(
              labelText: 'PIN Code',
              hintText: '123456',
              helperText: 'Enter your 6-digit PIN code',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: _focusNode.hasFocus
                      ? TunioColors.primary
                      : Colors.grey[300]!,
                  width: _focusNode.hasFocus ? 3 : 2,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                  color: TunioColors.primary,
                  width: 3,
                ),
              ),
              counterText: '${_digits.join('').length}/$_codeLength',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: _digits.join('').isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _textController.clear();
                        _onTextChanged('');
                      },
                    )
                  : null,
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 6,
            ),
            maxLength: _codeLength,
            autofocus: true,
          ),
          const SizedBox(height: 8),
          Text(
            _focusNode.hasFocus
                ? 'Use number keys on remote control or keyboard'
                : 'Click to focus and enter digits',
            style: TextStyle(
              fontSize: 12,
              color:
                  _focusNode.hasFocus ? TunioColors.primary : Colors.grey[600],
              fontWeight:
                  _focusNode.hasFocus ? FontWeight.w500 : FontWeight.normal,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _isMobile ? _buildMobileInput() : _buildDesktopInput();
  }
}
