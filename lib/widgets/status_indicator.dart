import 'package:flutter/material.dart';
import '../services/audio_service.dart';
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
        return TunioColors.primary;
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
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600; // Mobile breakpoint

    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isMobile) ...[
              // Mobile layout: Two rows
              _buildMobileStatusRow(),
              if (isConnected) ...[
                const SizedBox(height: 8),
                _buildMobileMetricsRow(),
              ],
            ] else ...[
              // Desktop/Tablet layout: Single row
              _buildDesktopRow(),
            ],
            if (isConnected && reconnectCount > 0) ...[
              const SizedBox(height: 8),
              _buildReconnectInfo(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMobileStatusRow() {
    return Row(
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
          Tooltip(
            message: 'Trying to reconnect...',
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _getMainColor(),
              ),
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
                      ? TunioColors.primary
                      : Colors.transparent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                onPressed: onReconnect,
                icon: const Icon(Icons.refresh),
                iconSize: 20,
                tooltip: 'Reconnect to stream',
                color: TunioColors.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMobileMetricsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _buildQualityBadgeWithTooltip(),
        const SizedBox(width: 6),
        _buildBufferIndicatorWithTooltip(),
        const SizedBox(width: 6),
        if (pingMs != null) ...[
          _buildPingIndicatorWithTooltip(),
          const SizedBox(width: 6),
        ],
        _buildNetworkIndicatorWithTooltip(),
      ],
    );
  }

  Widget _buildDesktopRow() {
    return Row(
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
        const Spacer(),
        if (isConnected) ...[
          _buildQualityBadgeWithTooltip(),
          const SizedBox(width: 6),
          _buildBufferIndicatorWithTooltip(),
          const SizedBox(width: 6),
          if (pingMs != null) ...[
            _buildPingIndicatorWithTooltip(),
            const SizedBox(width: 6),
          ],
          _buildNetworkIndicatorWithTooltip(),
          const SizedBox(width: 6),
        ],
        if (isRetrying) ...[
          Tooltip(
            message: 'Trying to reconnect...',
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _getMainColor(),
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        if (statusMessage.contains('error') &&
            !statusMessage.contains('retrying') &&
            !isRetrying &&
            onReconnect != null) ...[
          Focus(
            focusNode: refreshButtonFocusNode,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: refreshButtonFocusNode?.hasFocus == true
                      ? TunioColors.primary
                      : Colors.transparent,
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                onPressed: onReconnect,
                icon: const Icon(Icons.refresh),
                iconSize: 20,
                tooltip: 'Reconnect to stream',
                color: TunioColors.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildQualityBadgeWithTooltip() {
    return Tooltip(
      message:
          'Connection Quality: $connectionQuality\n• Good: Stable streaming\n• Fair: Minor interruptions\n• Poor: Frequent buffering',
      child: _buildQualityBadge(),
    );
  }

  Widget _buildBufferIndicatorWithTooltip() {
    final seconds = bufferSize.inSeconds;
    String description;
    if (seconds >= 8) {
      description = 'Excellent buffer (${seconds}s)\nNo interruptions expected';
    } else if (seconds >= 5) {
      description = 'Good buffer (${seconds}s)\nStable playback';
    } else if (seconds >= 2) {
      description = 'Low buffer (${seconds}s)\nPossible interruptions';
    } else {
      description = 'Critical buffer (${seconds}s)\nBuffering likely';
    }

    return Tooltip(
      message: 'Stream Buffer: $description',
      child: _buildBufferIndicator(),
    );
  }

  Widget _buildPingIndicatorWithTooltip() {
    final ping = pingMs!;
    String description;
    if (ping <= 50) {
      description = 'Excellent (${ping}ms)\nVery fast response';
    } else if (ping <= 150) {
      description = 'Good (${ping}ms)\nNormal response time';
    } else {
      description = 'Slow (${ping}ms)\nHigh latency detected';
    }

    return Tooltip(
      message: 'Server Ping: $description',
      child: _buildPingIndicator(),
    );
  }

  Widget _buildNetworkIndicatorWithTooltip() {
    final status = isNetworkAvailable ? 'Connected' : 'Disconnected';
    final description = isNetworkAvailable
        ? 'Internet connection is available'
        : 'No internet connection detected';

    return Tooltip(
      message: 'Network Status: $status\n$description',
      child: _buildNetworkIndicator(),
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

    return SizedBox(
      width: 48, // Fixed width for Buffer indicator
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
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

    return SizedBox(
      width: 70, // Fixed width for Ping indicator (handles 1000ms+)
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
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
      ),
    );
  }

  Widget _buildNetworkIndicator() {
    final color = isNetworkAvailable ? Colors.green : Colors.red;
    final icon = isNetworkAvailable ? Icons.wifi : Icons.wifi_off;
    final text = isNetworkAvailable ? 'OK' : 'No Net';

    return SizedBox(
      width: 60, // Fixed width for Network indicator
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
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

    return SizedBox(
      width: 50, // Fixed width for Quality badge
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color),
        ),
        child: Center(
          child: Text(
            connectionQuality,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
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
        return TunioColors.primary;
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
