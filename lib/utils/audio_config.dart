import 'package:just_audio/just_audio.dart';
import '../utils/logger.dart';

class AudioConfig {
  // Two-level buffering strategy (like YouTube)
  // Level 1: Quick start with minimal buffer
  static const Duration quickStartBuffer = Duration(seconds: 3);

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
  static const Duration simpleMinBuffer =
      Duration(seconds: 2); // Minimal buffer
  static const Duration simpleMaxBuffer =
      Duration(seconds: 10); // Reasonable maximum
  static const int simpleTargetBytes =
      2 * 1024 * 1024; // 2MB - simple and effective

  static AudioLoadConfiguration getStreamingConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // OPTIMIZED: Android-specific buffering strategy
        minBufferDuration: quickStartBuffer, // Start with 3s minimum
        maxBufferDuration: maxBufferDuration, // Build up to 60s maximum
        bufferForPlaybackDuration: Duration(seconds: 2), // Quick start (2s)
        bufferForPlaybackAfterRebufferDuration:
            rebufferPlaybackBuffer, // Recovery (8s)
        targetBufferBytes:
            androidTargetBufferBytes, // 8MB - increased for better buffering
        prioritizeTimeOverSizeThresholds:
            true, // Priority to time - allows buffer growth
        backBufferDuration: backBufferDuration,
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false, // Don't wait - fast start
        preferredForwardBufferDuration: forwardBufferDuration,
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: maxBitRate.toDouble(),
      ),
    );
  }

  static Map<String, String> getStreamingHeaders() {
    return {
      'User-Agent': userAgent,
      'Icy-MetaData': '1',
      'Connection': 'keep-alive',
      'Cache-Control': 'no-cache',
      'Accept': 'audio/*,*/*;q=0.8',
      'Range': 'bytes=0-',
      'Accept-Encoding': 'identity', // Prefer no compression for streaming
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

  // ALTERNATIVE: Simple configuration that might work better on Android TV
  static AudioLoadConfiguration getSimpleStreamingConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Simplified settings - sometimes complex settings don't work on TV
        minBufferDuration: Duration(seconds: 5), // Simple minimum
        maxBufferDuration:
            Duration(seconds: 60), // Increased to 60s to allow more buffer
        bufferForPlaybackDuration: Duration(seconds: 3), // Quick start
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5), // Resume
        targetBufferBytes:
            8 * 1024 * 1024, // 8MB - increased to force more buffering
        prioritizeTimeOverSizeThresholds: true,
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: true, // Let system handle
        preferredForwardBufferDuration:
            Duration(seconds: 25), // STEP 2: 15->25 for better macOS buffering
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: 192000,
      ),
    );
  }

  // Gentle improvement to simple config for better Android buffering
  static AudioLoadConfiguration getImprovedSimpleConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Conservative improvements to simple config
        minBufferDuration: Duration(seconds: 5), // Keep same
        maxBufferDuration: Duration(seconds: 45), // Modest increase 30->45
        bufferForPlaybackDuration:
            Duration(seconds: 2), // Slightly faster start
        bufferForPlaybackAfterRebufferDuration:
            Duration(seconds: 6), // Slightly more recovery
        targetBufferBytes: 5 * 1024 * 1024, // Modest increase to 5MB
        prioritizeTimeOverSizeThresholds: true, // Allow buffer growth
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: true,
        preferredForwardBufferDuration:
            Duration(seconds: 20), // Modest increase
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: 256000, // Modest increase
      ),
    );
  }

  // ALTERNATIVE: Aggressive Android configuration for problematic devices
  static AudioLoadConfiguration getAggressiveAndroidConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Very aggressive buffering for Android devices with buffer issues
        minBufferDuration: Duration(seconds: 2), // Quick start
        maxBufferDuration: Duration(seconds: 90), // Allow large buffers
        bufferForPlaybackDuration: Duration(seconds: 1), // Start very fast
        bufferForPlaybackAfterRebufferDuration:
            Duration(seconds: 5), // Resume fast
        targetBufferBytes: 16 * 1024 * 1024, // 16MB target
        prioritizeTimeOverSizeThresholds:
            true, // Time priority for buffer growth
        backBufferDuration: Duration(seconds: 3),
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: Duration(seconds: 45),
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: maxBitRate.toDouble(),
      ),
    );
  }

  // Special configuration for Android TV/Set-top boxes
  static AudioLoadConfiguration getTVStreamingConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // TV-optimized buffering
        minBufferDuration: Duration(seconds: 3), // TV quick start
        maxBufferDuration: Duration(seconds: 45), // TV memory constraints
        bufferForPlaybackDuration: Duration(seconds: 1), // Start faster on TV
        bufferForPlaybackAfterRebufferDuration:
            Duration(seconds: 3), // Resume faster
        targetBufferBytes: tvTargetBufferBytes, // 4MB for TV
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 3), // Less back buffer for TV
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: Duration(seconds: 20), // TV buffer
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: 192000, // Lower bitrate for TV stability
      ),
    );
  }

  // Simplified Live Stream configuration - focus on stability, not big buffers
  static AudioLoadConfiguration getSimpleLiveStreamConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Simple settings optimized for live streaming
        minBufferDuration: simpleMinBuffer, // 2s minimum
        maxBufferDuration:
            simpleMaxBuffer, // 10s maximum - prevent infinite growth
        bufferForPlaybackDuration: Duration(seconds: 1), // Quick start
        bufferForPlaybackAfterRebufferDuration:
            Duration(seconds: 3), // Quick recovery
        targetBufferBytes: simpleTargetBytes, // 2MB - simple target
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 1), // Minimal back buffer
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false,
        preferredForwardBufferDuration: Duration(seconds: 8), // Simple 8s ahead
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: 256000, // Reasonable bitrate
      ),
    );
  }

  static bool isAndroidTV() {
    // This would need platform-specific detection
    // For now, we'll add logging to help identify TV devices
    return false; // Will be detected at runtime
  }

  // Adaptive configuration selection based on device capabilities
  static AudioLoadConfiguration getAdaptiveConfiguration() {
    // For now, start with improved configuration
    // Later can be enhanced with device detection logic
    return getStreamingConfiguration();
  }

  // Method to get aggressive configuration for devices with buffer issues
  static AudioLoadConfiguration getConfigurationForBufferIssues() {
    Logger.info(
        '⚠️ AudioConfig: Switching to aggressive buffer configuration due to buffer growth issues',
        'AudioConfig');
    return getAggressiveAndroidConfiguration();
  }

  // Diagnostic method to log current buffer configuration
  static void logBufferConfiguration(String configName) {
    Logger.info(
        '📊 AudioConfig: Using $configName - targetBufferBytes: ${androidTargetBufferBytes ~/ (1024 * 1024)}MB, maxBuffer: ${maxBufferDuration.inSeconds}s',
        'AudioConfig');
  }
}
