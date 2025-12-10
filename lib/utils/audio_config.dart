import 'package:just_audio/just_audio.dart';

import '../utils/logger.dart';
import '../utils/platform_info.dart';

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

  // Specialized targets for different stream types
  static const Duration hlsTargetForwardBuffer = Duration(seconds: 35);
  static const Duration hlsMinBufferDuration = Duration(seconds: 28);
  static const Duration hlsMaxBufferDuration = Duration(seconds: 60);
  static const Duration hlsPlaybackStartBuffer = Duration(seconds: 1);
  static const Duration hlsRebufferStartBuffer = Duration(seconds: 5);

  static const Duration liveMinBufferDuration = Duration(seconds: 5);
  static const Duration liveMaxBufferDuration = Duration(seconds: 15);
  static const Duration livePlaybackStartBuffer = Duration(milliseconds: 1500);
  static const Duration liveRebufferStartBuffer = Duration(seconds: 3);
  static const Duration livePreferredForwardBufferDuration =
      Duration(seconds: 8);

  // Android-specific prebuffer delay
  static const Duration androidPrebufferDelay =
      Duration(seconds: 5); // Android workaround
  static const Duration androidFastPrebuffer =
      Duration(seconds: 2); // Fast devices/good network
  static const Duration androidSlowPrebuffer =
      Duration(seconds: 5); // Slow devices/poor network
  static const Duration androidTVPrebuffer = Duration(seconds: 4); // TV devices
  static const int hlsTargetBufferBytes = 12 * 1024 * 1024;

  // Network and quality settings - Optimized for live radio streams
  static const int targetBufferBytes = 4 *
      1024 *
      1024; // 4MB - optimal for live streams, reduces memory pressure
  static const int androidTargetBufferBytes =
      4 * 1024 * 1024; // 4MB for Android - balanced stability and memory usage
  static const int tvTargetBufferBytes =
      12 * 1024 * 1024; // Increased to 12MB for TV
  static const int maxBitRate = 320000; // 320 kbps
  static const double maxBitRateDouble = 320000.0;
  // Use platform-aware user agent
  static String get userAgent => PlatformInfo.userAgent;

  // Buffer health monitoring
  static const Duration bufferCheckInterval = Duration(seconds: 2);
  static const int lowBufferThresholdSeconds = 5; // Critical threshold
  static const int goodBufferThresholdSeconds = 10; // Healthy threshold
  static const int excellentBufferThresholdSeconds = 20; // Excellent threshold

  // Live streaming optimized approach for Icecast2
  static const Duration liveStreamStartupDelay =
      Duration(seconds: 2); // Reduced for faster startup
  static const Duration liveStreamFastStartup =
      Duration(seconds: 1); // Very fast for good connections
  static const Duration liveStreamSlowStartup =
      Duration(seconds: 3); // Moderate for poor connections

  // Simple live stream settings - no complex buffering
  static const Duration simpleMinBuffer = Duration(seconds: 5); // Stable buffer
  static const Duration simpleMaxBuffer =
      Duration(seconds: 10); // Reasonable maximum
  static const int simpleTargetBytes =
      2 * 1024 * 1024; // 2MB - simple and effective

  static Map<String, String> getStreamingHeaders() {
    return {
      'User-Agent': userAgent,
      'Platform': PlatformInfo.platform,
      'Accept': '*/*',
      'Connection': 'keep-alive',
      'Icy-MetaData': '1', // Request Icecast2 metadata
      'Cache-Control': 'no-cache', // Disable caching for live streams
      'Accept-Encoding': 'identity', // Disable compression for live streams
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

  static AudioLoadConfiguration buildLoadConfiguration({
    required bool isHls,
  }) {
    if (isHls) {
      Logger.info(
          '🎯 AudioConfig: Building HLS load configuration (target ${hlsTargetForwardBuffer.inSeconds}s buffer)',
          'AudioConfig');
      return AudioLoadConfiguration(
        darwinLoadControl: const DarwinLoadControl(
          automaticallyWaitsToMinimizeStalling: false,
          preferredForwardBufferDuration: hlsTargetForwardBuffer,
          canUseNetworkResourcesForLiveStreamingWhilePaused: true,
          preferredPeakBitRate: maxBitRateDouble,
        ),
        androidLoadControl: const AndroidLoadControl(
          minBufferDuration: hlsMinBufferDuration,
          maxBufferDuration: hlsMaxBufferDuration,
          bufferForPlaybackDuration: hlsPlaybackStartBuffer,
          bufferForPlaybackAfterRebufferDuration: hlsRebufferStartBuffer,
          targetBufferBytes: hlsTargetBufferBytes,
          prioritizeTimeOverSizeThresholds: true,
          backBufferDuration: backBufferDuration,
        ),
      );
    }

    Logger.info(
        '🎯 AudioConfig: Building live stream load configuration (target ${liveMinBufferDuration.inSeconds}s buffer)',
        'AudioConfig');
    return AudioLoadConfiguration(
      darwinLoadControl: const DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: livePreferredForwardBufferDuration,
        canUseNetworkResourcesForLiveStreamingWhilePaused: false,
        preferredPeakBitRate: maxBitRateDouble,
      ),
      androidLoadControl: const AndroidLoadControl(
        minBufferDuration: liveMinBufferDuration,
        maxBufferDuration: liveMaxBufferDuration,
        bufferForPlaybackDuration: livePlaybackStartBuffer,
        bufferForPlaybackAfterRebufferDuration: liveRebufferStartBuffer,
        targetBufferBytes: androidTargetBufferBytes,
        prioritizeTimeOverSizeThresholds: false,
        backBufferDuration: backBufferDuration,
      ),
    );
  }
}
