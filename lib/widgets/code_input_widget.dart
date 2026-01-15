import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart' show TunioColors;
import 'package:flutter/foundation.dart';

class CodeInputWidget extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final VoidCallback? onSubmitted;
  final VoidCallback? onTap;
  final bool enabled;
  final FocusNode? focusNode;

  const CodeInputWidget({
    super.key,
    required this.value,
    required this.onChanged,
    this.onSubmitted,
    this.onTap,
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
  String _lastSubmittedValue = '';

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
    _focusNode.addListener(_handleFocusChange);
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
    // Reset auto-submit tracking when value is incomplete
    if (value.length < _codeLength) {
      _lastSubmittedValue = '';
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

  void _handleFocusChange() {
    if (!mounted) return;
    setState(() {});
    if (!_focusNode.hasFocus || !widget.enabled) return;
    widget.onTap?.call();
    if (_textController.text.isNotEmpty) {
      _textController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _textController.text.length,
      );
    }
    final navigationMode = MediaQuery.maybeOf(context)?.navigationMode;
    if (navigationMode == NavigationMode.directional) {
      SystemChannels.textInput.invokeMethod('TextInput.show');
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

      if (cleanText.length == _codeLength && cleanText != _lastSubmittedValue) {
        _lastSubmittedValue = cleanText;
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

  Widget _buildDesktopInput(
      {required bool isDirectionalNav, required bool isMobile}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Column(
        children: [
          Text(
            'Enter 6-digit code',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18,
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
            onTap: widget.onTap,
            onSubmitted: (_) {
              if (!widget.enabled) return;
              final cleanText =
                  _textController.text.replaceAll(RegExp(r'\D'), '');
              if (cleanText.length == _codeLength) {
                widget.onSubmitted?.call();
              }
            },
            decoration: InputDecoration(
              labelText: 'PIN Code',
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
            style: TextStyle(
              fontSize: isMobile ? 18 : 20,
              fontWeight: FontWeight.bold,
              letterSpacing: isMobile ? 4 : 6,
              color: isDark ? Colors.white : Colors.black,
            ),
            maxLength: _codeLength,
            textInputAction: TextInputAction.done,
            autofocus: isDirectionalNav || !isMobile,
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 8),
          Text(
            _focusNode.hasFocus
                ? (isDirectionalNav
                    ? 'Use on-screen keyboard or number keys'
                    : (isMobile
                        ? 'Use on-screen keyboard to enter digits'
                        : 'Use number keys on remote control or keyboard'))
                : (isMobile
                    ? 'Tap to enter code'
                    : 'Click to focus and enter digits'),
            style: TextStyle(
              fontSize: 12,
              color: _focusNode.hasFocus
                  ? (isDark ? Colors.white : TunioColors.primary)
                  : (isDark ? Colors.grey[400] : Colors.grey[600]),
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
    final navigationMode = MediaQuery.maybeOf(context)?.navigationMode;
    final isDirectionalNav = navigationMode == NavigationMode.directional;
    return _buildDesktopInput(
      isDirectionalNav: isDirectionalNav,
      isMobile: _isMobile,
    );
  }
}
