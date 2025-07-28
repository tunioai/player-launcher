import '../utils/logger.dart';

class AudioConfig {
  // Two-level buffering strategy (like YouTube)
  // Level 1: Quick start with minimal buffer
  static const Duration quickStartBuffer = Duration(seconds: 5);

  // Level 2: Target buffer during playback
  static const Duration targetPlaybackBuffer = Duration(seconds: 15);
  static const Duration maxBufferDuration = Duration(seconds: 60);

  // Recovery buffer (after network issues)
  static const Duration rebufferPlaybackBuffer = Duration(seconds: 8);

  // Platform-specific buffers
  static const Duration forwardBufferDuration =
      Duration(seconds: 30); // iOS/macOS
  static const Duration backBufferDuration = Duration(seconds: 5);

  // Android-specific prebuffer delay
  static const Duration androidPrebufferDelay =
      Duration(seconds: 5); // Android workaround
  static const Duration androidFastPrebuffer =
      Duration(seconds: 2); // Fast devices/good network
  static const Duration androidSlowPrebuffer =
      Duration(seconds: 5); // Slow devices/poor network
  static const Duration androidTVPrebuffer = Duration(seconds: 4); // TV devices

  // Network and quality settings
  static const int targetBufferBytes =
      8 * 1024 * 1024; // 8MB (increased for Android)
  static const int androidTargetBufferBytes =
      8 * 1024 * 1024; // 8MB for Android
  static const int tvTargetBufferBytes = 4 * 1024 * 1024; // 4MB for TV
  static const int maxBitRate = 320000; // 320 kbps
  static const String userAgent = 'TunioRadioPlayer/1.0 (Mobile; Streaming)';

  // Buffer health monitoring
  static const Duration bufferCheckInterval = Duration(seconds: 2);
  static const int lowBufferThresholdSeconds = 5; // Critical threshold
  static const int goodBufferThresholdSeconds = 10; // Healthy threshold
  static const int excellentBufferThresholdSeconds = 20; // Excellent threshold

  // Live streaming simplified approach
  static const Duration liveStreamStartupDelay =
      Duration(seconds: 4); // Configurable startup delay (tested: 2s, 4s work)
  static const Duration liveStreamFastStartup =
      Duration(seconds: 2); // Fast networks
  static const Duration liveStreamSlowStartup =
      Duration(seconds: 6); // Slow networks

  // Simple live stream settings - no complex buffering
  static const Duration simpleMinBuffer = Duration(seconds: 5); // Stable buffer
  static const Duration simpleMaxBuffer =
      Duration(seconds: 10); // Reasonable maximum
  static const int simpleTargetBytes =
      2 * 1024 * 1024; // 2MB - simple and effective

  static Map<String, String> getStreamingHeaders() {
    return {
      'User-Agent': userAgent,
      // Minimal headers - only User-Agent to avoid conflicts
    };
  }

  static String getBufferStatusDescription(Duration bufferAhead) {
    final seconds = bufferAhead.inSeconds;
    if (seconds < lowBufferThresholdSeconds) {
      return 'Critical buffer (${seconds}s)';
    } else if (seconds < goodBufferThresholdSeconds) {
      return 'Building buffer (${seconds}s)';
    } else if (seconds < excellentBufferThresholdSeconds) {
      return 'Good buffer (${seconds}s)';
    } else {
      return 'Excellent buffer (${seconds}s)';
    }
  }

  static bool isBufferHealthy(Duration bufferAhead) {
    return bufferAhead.inSeconds >= goodBufferThresholdSeconds;
  }

  static bool isBufferCritical(Duration bufferAhead) {
    return bufferAhead.inSeconds < lowBufferThresholdSeconds;
  }

  static bool isBufferExcellent(Duration bufferAhead) {
    return bufferAhead.inSeconds >= excellentBufferThresholdSeconds;
  }

  static bool isAndroidTV() {
    // This would need platform-specific detection
    // For now, we'll add logging to help identify TV devices
    return false; // Will be detected at runtime
  }

  // Diagnostic method to log current buffer configuration
  static void logBufferConfiguration(String configName) {
    Logger.info(
        '📊 AudioConfig: Using $configName - targetBufferBytes: ${androidTargetBufferBytes ~/ (1024 * 1024)}MB, maxBuffer: ${maxBufferDuration.inSeconds}s',
        'AudioConfig');
  }
}
