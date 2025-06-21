import 'package:just_audio/just_audio.dart';

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

  // Network and quality settings
  static const int targetBufferBytes = 3 * 1024 * 1024; // 3MB (optimized)
  static const int maxBitRate = 320000; // 320 kbps
  static const String userAgent = 'TunioRadioPlayer/1.0 (Mobile; Streaming)';

  // Buffer health monitoring
  static const Duration bufferCheckInterval = Duration(seconds: 2);
  static const int lowBufferThresholdSeconds = 5; // Critical threshold
  static const int goodBufferThresholdSeconds = 10; // Healthy threshold
  static const int excellentBufferThresholdSeconds = 20; // Excellent threshold

  static AudioLoadConfiguration getStreamingConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // FIXED: Two-level buffering strategy
        minBufferDuration:
            quickStartBuffer, // Start with 2s minimum (CRITICAL!)
        maxBufferDuration: maxBufferDuration, // Build up to 60s maximum
        bufferForPlaybackDuration: quickStartBuffer, // Fast start (2s)
        bufferForPlaybackAfterRebufferDuration:
            rebufferPlaybackBuffer, // Recovery (8s)
        targetBufferBytes: targetBufferBytes,
        prioritizeTimeOverSizeThresholds: false, // Let ExoPlayer manage both
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
        maxBufferDuration: Duration(seconds: 30), // Reasonable maximum
        bufferForPlaybackDuration: Duration(seconds: 2), // Quick start
        bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5), // Resume
        // Remove complex settings that might not work on TV
        prioritizeTimeOverSizeThresholds: true,
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: true, // Let system handle
        preferredForwardBufferDuration: Duration(seconds: 15),
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: 192000,
      ),
    );
  }

  // Special configuration for Android TV/Set-top boxes
  static AudioLoadConfiguration getTVStreamingConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // More aggressive buffering for TV devices
        minBufferDuration: Duration(seconds: 15), // Reduced for TV
        maxBufferDuration:
            Duration(seconds: 60), // Reduced for TV memory constraints
        bufferForPlaybackDuration: Duration(seconds: 1), // Start faster on TV
        bufferForPlaybackAfterRebufferDuration:
            Duration(seconds: 3), // Resume faster
        targetBufferBytes: 2 * 1024 * 1024, // 2MB for TV (less memory)
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: Duration(seconds: 5), // Less back buffer for TV
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: false, // Don't wait on TV
        preferredForwardBufferDuration:
            Duration(seconds: 30), // Less buffer on TV
        canUseNetworkResourcesForLiveStreamingWhilePaused: true,
        preferredPeakBitRate: 192000, // Lower bitrate for TV stability
      ),
    );
  }

  static bool isAndroidTV() {
    // This would need platform-specific detection
    // For now, we'll add logging to help identify TV devices
    return false; // Will be detected at runtime
  }
}
