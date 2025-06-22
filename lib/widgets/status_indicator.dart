import 'package:flutter/material.dart';
import '../services/audio_service.dart';

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

    switch (audioState) {
      case AudioState.playing:
        return Icons.play_circle;
      case AudioState.paused:
        return Icons.pause_circle;
      case AudioState.loading:
      case AudioState.buffering:
        return Icons.refresh;
      case AudioState.error:
        return Icons.error;
      case AudioState.idle:
        return Icons.radio;
    }
  }

  Color _getIconColor() {
    if (!isConnected) {
      return Colors.grey;
    }

    switch (audioState) {
      case AudioState.playing:
        return Colors.green;
      case AudioState.paused:
        return Colors.blue;
      case AudioState.loading:
      case AudioState.buffering:
        return Colors.orange;
      case AudioState.error:
        return Colors.red;
      case AudioState.idle:
        return Colors.grey;
    }
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
    return audioState == AudioState.loading ||
        audioState == AudioState.buffering;
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

class StreamNetworkIndicator extends StatelessWidget {
  final AudioState audioState;
  final bool isConnected;
  final String connectionQuality;
  final Duration bufferSize;
  final int? pingMs;
  final int reconnectCount;
  final bool isNetworkAvailable;
  final String statusMessage;
  final bool isRetrying;
  final VoidCallback? onReconnect;
  final FocusNode? refreshButtonFocusNode;

  const StreamNetworkIndicator({
    super.key,
    required this.audioState,
    required this.isConnected,
    required this.connectionQuality,
    required this.bufferSize,
    this.pingMs,
    this.reconnectCount = 0,
    this.isNetworkAvailable = true,
    required this.statusMessage,
    this.isRetrying = false,
    this.onReconnect,
    this.refreshButtonFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _getMainIcon(),
                  color: _getMainColor(),
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    statusMessage,
                    style: TextStyle(
                      color: _getMainColor(),
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (isRetrying) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _getMainColor(),
                    ),
                  ),
                ],
                if (statusMessage.contains('error') &&
                    !statusMessage.contains('retrying') &&
                    !isRetrying &&
                    onReconnect != null) ...[
                  const SizedBox(width: 8),
                  Focus(
                    focusNode: refreshButtonFocusNode,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: refreshButtonFocusNode?.hasFocus == true
                              ? Colors.blue
                              : Colors.transparent,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        onPressed: onReconnect,
                        icon: const Icon(Icons.refresh),
                        iconSize: 20,
                        tooltip: 'Reconnect',
                        color: Colors.blue,
                      ),
                    ),
                  ),
                ],
                _buildQualityBadge(),
              ],
            ),
            if (isConnected) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _buildBufferIndicator()),
                  const SizedBox(width: 8),
                  if (pingMs != null) Expanded(child: _buildPingIndicator()),
                  if (pingMs != null) const SizedBox(width: 8),
                  Expanded(child: _buildNetworkIndicator()),
                ],
              ),
              if (reconnectCount > 0) ...[
                const SizedBox(height: 4),
                _buildReconnectInfo(),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBufferIndicator() {
    final seconds = bufferSize.inSeconds;
    Color color;
    IconData icon;

    if (seconds >= 8) {
      color = Colors.green;
      icon = Icons.signal_wifi_4_bar;
    } else if (seconds >= 5) {
      color = Colors.orange;
      icon = Icons.network_wifi_3_bar;
    } else if (seconds >= 2) {
      color = Colors.orange;
      icon = Icons.network_wifi_2_bar;
    } else {
      color = Colors.red;
      icon = Icons.network_wifi_1_bar;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '${seconds}s',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPingIndicator() {
    final ping = pingMs!;
    Color color;
    IconData icon;

    if (ping <= 50) {
      color = Colors.green;
      icon = Icons.speed;
    } else if (ping <= 150) {
      color = Colors.orange;
      icon = Icons.timer;
    } else {
      color = Colors.red;
      icon = Icons.timer_off;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '${ping}ms',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNetworkIndicator() {
    final color = isNetworkAvailable ? Colors.green : Colors.red;
    final icon = isNetworkAvailable ? Icons.wifi : Icons.wifi_off;
    final text = isNetworkAvailable ? 'OK' : 'No Net';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityBadge() {
    Color color;
    switch (connectionQuality) {
      case "Poor":
        color = Colors.red;
        break;
      case "Fair":
        color = Colors.orange;
        break;
      case "Good":
        color = Colors.green;
        break;
      default:
        color = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color),
      ),
      child: Text(
        connectionQuality,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildReconnectInfo() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.refresh,
            size: 10,
            color: Colors.orange,
          ),
          const SizedBox(width: 4),
          Text(
            'Reconnected $reconnectCount times',
            style: TextStyle(
              fontSize: 9,
              color: Colors.orange,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  IconData _getMainIcon() {
    if (!isConnected || !isNetworkAvailable) {
      return Icons.cloud_off;
    }

    switch (audioState) {
      case AudioState.playing:
        return Icons.radio;
      case AudioState.paused:
        return Icons.pause_circle;
      case AudioState.loading:
      case AudioState.buffering:
        return Icons.refresh;
      case AudioState.error:
        return Icons.error;
      case AudioState.idle:
        return Icons.radio_button_unchecked;
    }
  }

  Color _getMainColor() {
    if (!isNetworkAvailable) {
      return Colors.grey;
    }

    if (!isConnected) {
      return Colors.red;
    }

    switch (audioState) {
      case AudioState.playing:
        return connectionQuality == "Poor" ? Colors.orange : Colors.green;
      case AudioState.paused:
        return Colors.blue;
      case AudioState.loading:
      case AudioState.buffering:
        return Colors.orange;
      case AudioState.error:
        return Colors.red;
      case AudioState.idle:
        return Colors.grey;
    }
  }
}
