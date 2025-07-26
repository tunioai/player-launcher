import '../models/stream_config.dart';

/// Enhanced audio state with metadata and statistics
sealed class AudioState {
  const AudioState();

  bool get isActive => switch (this) {
        AudioStateIdle() => false,
        AudioStateLoading() => true,
        AudioStateBuffering() => true,
        AudioStatePlaying() => true,
        AudioStatePaused() => true,
        AudioStateError() => false,
      };

  bool get isPlaying => this is AudioStatePlaying;
  bool get canPause => isPlaying;
  bool get canPlay => !isActive || this is AudioStatePaused;

  StreamConfig? get config => switch (this) {
        AudioStateIdle() => null,
        AudioStateLoading(:final config) => config,
        AudioStateBuffering(:final config) => config,
        AudioStatePlaying(:final config) => config,
        AudioStatePaused(:final config) => config,
        AudioStateError(:final config) => config,
      };

  String get displayMessage => switch (this) {
        AudioStateIdle() => 'Ready',
        AudioStateLoading() => 'Loading...',
        AudioStateBuffering() => 'Buffering...',
        AudioStatePlaying() => 'Playing',
        AudioStatePaused() => 'Paused',
        AudioStateError(:final message) => 'Error: $message',
      };
}

final class AudioStateIdle extends AudioState {
  const AudioStateIdle();

  @override
  bool operator ==(Object other) => other is AudioStateIdle;

  @override
  int get hashCode => runtimeType.hashCode;
}

final class AudioStateLoading extends AudioState {
  final StreamConfig config;
  final Duration elapsed;

  const AudioStateLoading({
    required this.config,
    this.elapsed = Duration.zero,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioStateLoading &&
          config == other.config &&
          elapsed == other.elapsed;

  @override
  int get hashCode => Object.hash(config, elapsed);
}

final class AudioStateBuffering extends AudioState {
  final StreamConfig config;
  final Duration bufferSize;
  final Duration elapsed;

  const AudioStateBuffering({
    required this.config,
    this.bufferSize = Duration.zero,
    this.elapsed = Duration.zero,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioStateBuffering &&
          config == other.config &&
          bufferSize == other.bufferSize &&
          elapsed == other.elapsed;

  @override
  int get hashCode => Object.hash(config, bufferSize, elapsed);
}

final class AudioStatePlaying extends AudioState {
  final StreamConfig config;
  final Duration position;
  final Duration bufferSize;
  final ConnectionQuality quality;
  final PlaybackStats stats;

  const AudioStatePlaying({
    required this.config,
    this.position = Duration.zero,
    this.bufferSize = Duration.zero,
    this.quality = ConnectionQuality.good,
    this.stats = const PlaybackStats(),
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioStatePlaying &&
          config == other.config &&
          position == other.position &&
          bufferSize == other.bufferSize &&
          quality == other.quality &&
          stats == other.stats;

  @override
  int get hashCode => Object.hash(config, position, bufferSize, quality, stats);
}

final class AudioStatePaused extends AudioState {
  final StreamConfig config;
  final Duration position;
  final Duration bufferSize;

  const AudioStatePaused({
    required this.config,
    this.position = Duration.zero,
    this.bufferSize = Duration.zero,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioStatePaused &&
          config == other.config &&
          position == other.position &&
          bufferSize == other.bufferSize;

  @override
  int get hashCode => Object.hash(config, position, bufferSize);
}

final class AudioStateError extends AudioState {
  final String message;
  final Exception? exception;
  final StreamConfig? config;
  final bool isRetryable;

  const AudioStateError({
    required this.message,
    this.exception,
    this.config,
    this.isRetryable = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioStateError &&
          message == other.message &&
          exception == other.exception &&
          config == other.config &&
          isRetryable == other.isRetryable;

  @override
  int get hashCode => Object.hash(message, exception, config, isRetryable);
}

/// Connection quality assessment
enum ConnectionQuality {
  poor,
  fair,
  good,
  excellent;

  String get displayName => switch (this) {
        ConnectionQuality.poor => 'Poor',
        ConnectionQuality.fair => 'Fair',
        ConnectionQuality.good => 'Good',
        ConnectionQuality.excellent => 'Excellent',
      };

  static ConnectionQuality fromBufferSize(Duration bufferSize) {
    final seconds = bufferSize.inSeconds;
    return switch (seconds) {
      <= 2 => ConnectionQuality.poor,
      <= 5 => ConnectionQuality.fair,
      <= 10 => ConnectionQuality.good,
      _ => ConnectionQuality.excellent,
    };
  }
}

/// Playback statistics
final class PlaybackStats {
  final Duration totalPlaytime;
  final int reconnectCount;
  final int bufferUnderruns;
  final Duration averageBuffer;
  final DateTime? lastReconnect;

  const PlaybackStats({
    this.totalPlaytime = Duration.zero,
    this.reconnectCount = 0,
    this.bufferUnderruns = 0,
    this.averageBuffer = Duration.zero,
    this.lastReconnect,
  });

  PlaybackStats copyWith({
    Duration? totalPlaytime,
    int? reconnectCount,
    int? bufferUnderruns,
    Duration? averageBuffer,
    DateTime? lastReconnect,
  }) =>
      PlaybackStats(
        totalPlaytime: totalPlaytime ?? this.totalPlaytime,
        reconnectCount: reconnectCount ?? this.reconnectCount,
        bufferUnderruns: bufferUnderruns ?? this.bufferUnderruns,
        averageBuffer: averageBuffer ?? this.averageBuffer,
        lastReconnect: lastReconnect ?? this.lastReconnect,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackStats &&
          totalPlaytime == other.totalPlaytime &&
          reconnectCount == other.reconnectCount &&
          bufferUnderruns == other.bufferUnderruns &&
          averageBuffer == other.averageBuffer &&
          lastReconnect == other.lastReconnect;

  @override
  int get hashCode => Object.hash(
        totalPlaytime,
        reconnectCount,
        bufferUnderruns,
        averageBuffer,
        lastReconnect,
      );
}

/// Radio connection state
sealed class RadioState {
  const RadioState();

  bool get isConnected => this is RadioStateConnected || this is RadioStateFailover;
  bool get isConnecting => this is RadioStateConnecting;
  bool get hasError => this is RadioStateError;
  bool get isFailover => this is RadioStateFailover;

  String? get token => switch (this) {
        RadioStateConnected(:final token) => token,
        RadioStateFailover(:final token) => token,
        _ => null,
      };

  StreamConfig? get config => switch (this) {
        RadioStateConnected(:final config) => config,
        RadioStateFailover(:final originalConfig) => originalConfig,
        _ => null,
      };
}

final class RadioStateDisconnected extends RadioState {
  final String message;

  const RadioStateDisconnected({this.message = 'Ready'});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioStateDisconnected && message == other.message;

  @override
  int get hashCode => message.hashCode;
}

final class RadioStateConnecting extends RadioState {
  final String message;
  final int attempt;

  const RadioStateConnecting({
    this.message = 'Connecting...',
    this.attempt = 0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioStateConnecting &&
          message == other.message &&
          attempt == other.attempt;

  @override
  int get hashCode => Object.hash(message, attempt);
}

final class RadioStateConnected extends RadioState {
  final String token;
  final StreamConfig config;
  final AudioState audioState;
  final bool isRetrying;

  const RadioStateConnected({
    required this.token,
    required this.config,
    required this.audioState,
    this.isRetrying = false,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioStateConnected &&
          token == other.token &&
          config == other.config &&
          audioState == other.audioState &&
          isRetrying == other.isRetrying;

  @override
  int get hashCode => Object.hash(token, config, audioState, isRetrying);
}

final class RadioStateError extends RadioState {
  final String message;
  final Exception? exception;
  final bool canRetry;
  final int attemptCount;

  const RadioStateError({
    required this.message,
    this.exception,
    this.canRetry = true,
    this.attemptCount = 0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioStateError &&
          message == other.message &&
          exception == other.exception &&
          canRetry == other.canRetry &&
          attemptCount == other.attemptCount;

  @override
  int get hashCode => Object.hash(message, exception, canRetry, attemptCount);
}

final class RadioStateFailover extends RadioState {
  final String token;
  final StreamConfig? originalConfig;
  final AudioState audioState;
  final String currentTrackPath;
  final int attemptCount;

  const RadioStateFailover({
    required this.token,
    this.originalConfig,
    required this.audioState,
    required this.currentTrackPath,
    this.attemptCount = 0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RadioStateFailover &&
          token == other.token &&
          originalConfig == other.originalConfig &&
          audioState == other.audioState &&
          currentTrackPath == other.currentTrackPath &&
          attemptCount == other.attemptCount;

  @override
  int get hashCode => Object.hash(token, originalConfig, audioState, currentTrackPath, attemptCount);
}

/// Network state information
final class NetworkState {
  final bool isConnected;
  final int? pingMs;
  final ConnectionType type;
  final DateTime? lastDisconnection;
  final Duration totalOfflineTime;

  const NetworkState({
    this.isConnected = false,
    this.pingMs,
    this.type = ConnectionType.unknown,
    this.lastDisconnection,
    this.totalOfflineTime = Duration.zero,
  });

  NetworkState copyWith({
    bool? isConnected,
    int? pingMs,
    ConnectionType? type,
    DateTime? lastDisconnection,
    Duration? totalOfflineTime,
  }) =>
      NetworkState(
        isConnected: isConnected ?? this.isConnected,
        pingMs: pingMs ?? this.pingMs,
        type: type ?? this.type,
        lastDisconnection: lastDisconnection ?? this.lastDisconnection,
        totalOfflineTime: totalOfflineTime ?? this.totalOfflineTime,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkState &&
          isConnected == other.isConnected &&
          pingMs == other.pingMs &&
          type == other.type &&
          lastDisconnection == other.lastDisconnection &&
          totalOfflineTime == other.totalOfflineTime;

  @override
  int get hashCode => Object.hash(
        isConnected,
        pingMs,
        type,
        lastDisconnection,
        totalOfflineTime,
      );
}

enum ConnectionType {
  wifi,
  mobile,
  ethernet,
  unknown;

  String get displayName => switch (this) {
        ConnectionType.wifi => 'WiFi',
        ConnectionType.mobile => 'Mobile',
        ConnectionType.ethernet => 'Ethernet',
        ConnectionType.unknown => 'Unknown',
      };
}
