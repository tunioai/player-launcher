import 'package:flutter/material.dart';
import '../core/audio_state.dart';
import '../main.dart' show TunioColors;

class StatusIndicator extends StatelessWidget {
  final AudioState audioState;
  final bool isConnected;
  final String statusMessage;

  const StatusIndicator({
    super.key,
    required this.audioState,
    required this.isConnected,
    required this.statusMessage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _getBackgroundColor(),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _getBorderColor(),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _getStatusIcon(),
            color: _getIconColor(),
            size: 16,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              statusMessage,
              style: TextStyle(
                color: _getTextColor(),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isLoading()) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(_getIconColor()),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getStatusIcon() {
    if (!isConnected) {
      return Icons.cloud_off;
    }

    return switch (audioState) {
      AudioStatePlaying() => Icons.play_circle,
      AudioStatePaused() => Icons.pause_circle,
      AudioStateLoading() || AudioStateBuffering() => Icons.refresh,
      AudioStateError() => Icons.error,
      AudioStateIdle() => Icons.radio,
    };
  }

  Color _getIconColor() {
    if (!isConnected) {
      return Colors.grey;
    }

    return switch (audioState) {
      AudioStatePlaying() => Colors.green,
      AudioStatePaused() => TunioColors.primary,
      AudioStateLoading() || AudioStateBuffering() => Colors.orange,
      AudioStateError() => Colors.red,
      AudioStateIdle() => Colors.grey,
    };
  }

  Color _getTextColor() {
    return _getIconColor();
  }

  Color _getBackgroundColor() {
    final baseColor = _getIconColor();
    return baseColor.withValues(alpha: 0.1);
  }

  Color _getBorderColor() {
    final baseColor = _getIconColor();
    return baseColor.withValues(alpha: 0.3);
  }

  bool _isLoading() {
    return audioState is AudioStateLoading || audioState is AudioStateBuffering;
  }
}

class ConnectionStatusBadge extends StatelessWidget {
  final bool isConnected;
  final String? title;

  const ConnectionStatusBadge({
    super.key,
    required this.isConnected,
    this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: isConnected ? Colors.green : Colors.red,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: (isConnected ? Colors.green : Colors.red)
                    .withValues(alpha: 0.3),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
          child: isConnected
              ? const Icon(
                  Icons.check,
                  color: Colors.white,
                  size: 12,
                )
              : const Icon(
                  Icons.close,
                  color: Colors.white,
                  size: 12,
                ),
        ),
        if (title != null) ...[
          const SizedBox(height: 4),
          Text(
            title!,
            style: TextStyle(
              fontSize: 10,
              color: isConnected ? Colors.green : Colors.red,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
