import 'package:just_audio/just_audio.dart';

class AudioConfig {
  // Streaming buffer settings optimized for radio/live streams
  static const Duration minBufferDuration = Duration(seconds: 30);
  static const Duration maxBufferDuration = Duration(seconds: 120);
  static const Duration initialPlaybackBuffer = Duration(seconds: 2);
  static const Duration rebufferPlaybackBuffer = Duration(seconds: 5);
  static const Duration forwardBufferDuration = Duration(seconds: 60);
  static const Duration backBufferDuration = Duration(seconds: 10);

  // Network and quality settings
  static const int targetBufferBytes = 5 * 1024 * 1024; // 5MB
  static const int maxBitRate = 320000; // 320 kbps
  static const String userAgent = 'TunioRadioPlayer/1.0 (Mobile; Streaming)';

  // Buffer monitoring settings
  static const Duration bufferCheckInterval = Duration(seconds: 5);
  static const int lowBufferThresholdSeconds = 10;
  static const int goodBufferThresholdSeconds = 30;

  static AudioLoadConfiguration getStreamingConfiguration() {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: minBufferDuration,
        maxBufferDuration: maxBufferDuration,
        bufferForPlaybackDuration: initialPlaybackBuffer,
        bufferForPlaybackAfterRebufferDuration: rebufferPlaybackBuffer,
        targetBufferBytes: targetBufferBytes,
        prioritizeTimeOverSizeThresholds: true,
        backBufferDuration: backBufferDuration,
      ),
      darwinLoadControl: DarwinLoadControl(
        automaticallyWaitsToMinimizeStalling: true,
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
    if (bufferAhead.inSeconds < lowBufferThresholdSeconds) {
      return 'Low buffer (${bufferAhead.inSeconds}s)';
    } else if (bufferAhead.inSeconds < goodBufferThresholdSeconds) {
      return 'Buffer OK (${bufferAhead.inSeconds}s)';
    } else {
      return 'Good buffer (${bufferAhead.inSeconds}s)';
    }
  }

  static bool isBufferHealthy(Duration bufferAhead) {
    return bufferAhead.inSeconds >= lowBufferThresholdSeconds;
  }
}
