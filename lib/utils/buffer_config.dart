/// User-configurable buffer settings
/// Change these values to customize buffering behavior
class BufferConfig {
  /// === QUICK START SETTINGS ===
  /// How long to buffer before starting playback (fast start)
  /// Lower = faster start, but more likely to stutter
  /// Higher = slower start, but more stable
  static const Duration quickStartBuffer = Duration(seconds: 5);

  /// === TARGET BUFFER SETTINGS ===
  /// Target buffer during normal playback
  /// This is what the player will try to maintain while playing
  static const Duration targetPlaybackBuffer = Duration(seconds: 15);

  /// === MAXIMUM BUFFER SETTINGS ===
  /// Maximum buffer allowed (to prevent excessive memory usage)
  static const Duration maxBufferDuration = Duration(seconds: 60);

  /// === RECOVERY SETTINGS ===
  /// How much to buffer after network interruption before resuming
  /// Higher = more stable recovery, lower = faster recovery
  static const Duration rebufferPlaybackBuffer = Duration(seconds: 8);

  /// === PLATFORM SPECIFIC ===
  /// iOS/macOS forward buffer (how much to buffer ahead)
  static const Duration forwardBufferDuration = Duration(seconds: 30);

  /// How much audio to keep behind current position (for seeking back)
  static const Duration backBufferDuration = Duration(seconds: 5);

  /// === MEMORY SETTINGS ===
  /// Target buffer size in bytes (3MB default)
  /// Lower for devices with limited memory (TV boxes)
  /// Higher for devices with more memory (modern phones)
  static const int targetBufferBytes = 3 * 1024 * 1024; // 3MB

  /// === QUALITY SETTINGS ===
  /// Maximum bitrate for streaming (320kbps default)
  /// Lower for unstable connections, higher for better quality
  static const int maxBitRate = 320000; // 320 kbps

  /// === HEALTH MONITORING ===
  /// Critical threshold - below this = red warning
  static const int criticalBufferSeconds = 5;

  /// Healthy threshold - above this = green indicator
  static const int healthyBufferSeconds = 10;

  /// Excellent threshold - above this = excellent buffer
  static const int excellentBufferSeconds = 20;

  /// === PRESETS ===

  /// Preset for fast devices with good network
  static BufferConfig get fastDevice => BufferConfig._(
        quickStart: Duration(seconds: 5),
        target: Duration(seconds: 20),
        max: Duration(seconds: 90),
        rebuffer: Duration(seconds: 5),
      );

  /// Preset for slow devices or poor network
  static BufferConfig get slowDevice => BufferConfig._(
        quickStart: Duration(seconds: 5),
        target: Duration(seconds: 10),
        max: Duration(seconds: 30),
        rebuffer: Duration(seconds: 10),
      );

  /// Preset for Android TV / Set-top boxes
  static BufferConfig get androidTV => BufferConfig._(
        quickStart: Duration(seconds: 5),
        target: Duration(seconds: 8),
        max: Duration(seconds: 25),
        rebuffer: Duration(seconds: 6),
      );

  // Private constructor for presets
  const BufferConfig._({
    required this.quickStart,
    required this.target,
    required this.max,
    required this.rebuffer,
  });

  final Duration quickStart;
  final Duration target;
  final Duration max;
  final Duration rebuffer;
}
