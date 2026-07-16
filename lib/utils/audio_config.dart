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

  // Live HLS starts at ExoPlayer's default live position (no explicit seek).
  // For a standard (non-LL) playlist with `#EXT-X-TARGETDURATION:6` this is
  // ~3×target = ~18s behind the live edge, i.e. the middle of the ~30s window:
  // enough forward buffer to ride out blips AND enough margin before the
  // trailing edge to avoid BehindLiveWindow errors. Seeking to Duration.zero
  // (the oldest segment) pinned playback to the trailing edge with zero margin
  // and made a healthy stream drop itself. Outage resilience comes from the
  // failover cache, not from riding the oldest segment.
  static const Duration? hlsInitialPosition = null;

  // Android-specific prebuffer delay
  static const Duration androidPrebufferDelay =
      Duration(seconds: 5); // Android workaround
  static const Duration androidFastPrebuffer =
      Duration(seconds: 2); // Fast devices/good network
  static const Duration androidSlowPrebuffer =
      Duration(seconds: 5); // Slow devices/poor network
  static const Duration androidTVPrebuffer = Duration(seconds: 4); // TV devices

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

  /// Single load configuration used for both HLS and live streams, so the
  /// AudioPlayer is created once for the app's lifetime (no per-stream-type
  /// recreation). Tuned for stability (generous buffering) over minimal
  /// latency, which suits an always-on radio appliance. Values are a starting
  /// point and can be tuned by on-device measurement.
  static AudioLoadConfiguration buildUnifiedLoadConfiguration() {
    Logger.info(
        '🎯 AudioConfig: Building unified load configuration (single player)',
        'AudioConfig');
    return AudioLoadConfiguration(
      darwinLoadControl: const DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: Duration(seconds: 30),
        canUseNetworkResourcesForLiveStreamingWhilePaused: false,
        preferredPeakBitRate: maxBitRateDouble,
      ),
      // Sized for a short (~30s) live HLS window played ~18s behind the edge:
      // ask for less forward buffer than the window can provide, and resume
      // quickly after a rebuffer instead of demanding a third of the window.
      // The former 28s min / 10s after-rebuffer left the player permanently
      // "under-buffered" and churning against a window that never holds 28s.
      androidLoadControl: const AndroidLoadControl(
        minBufferDuration: Duration(seconds: 15),
        maxBufferDuration: Duration(seconds: 30),
        bufferForPlaybackDuration: Duration(seconds: 2),
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 4),
        targetBufferBytes: 8 * 1024 * 1024,
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: backBufferDuration,
      ),
      // Keep ExoPlayer's default live speed control (0.97–1.03, pitch-preserved
      // via time-stretching) so the player actively maintains its target live
      // offset: it eases off when drifting toward the trailing edge (preventing
      // BehindLiveWindow) and catches up gently after a rebuffer. Pinning the
      // speed to exactly 1.0 disabled that correction and let the player drift
      // out of the live window.
      androidLivePlaybackSpeedControl: const AndroidLivePlaybackSpeedControl(),
    );
  }
}
