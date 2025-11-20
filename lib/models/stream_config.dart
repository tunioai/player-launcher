import '../utils/logger.dart';
import 'current_track.dart';

class StreamConfig {
  final String streamUrl;
  final double volume;
  final double? musicVolume;
  final String? title;
  final String? description;
  final CurrentTrack? current;
  final String? visualizerUrl;
  final String? streamUuid;

  const StreamConfig({
    required this.streamUrl,
    this.volume = 1.0,
    this.musicVolume,
    this.title,
    this.description,
    this.current,
    this.visualizerUrl,
    this.streamUuid,
  });

  /// Returns the volume value scaled for failover playback.
  ///
  /// The backend may provide a dedicated `music_volume` which represents
  /// the relative loudness of music within the master mix. When present we
  /// multiply the master `volume` by this value so that cached tracks match
  /// the perceived loudness of the live broadcast. If the field is missing we
  /// fall back to the legacy behaviour of using the master volume directly.
  double get failoverVolume {
    final master = volume.clamp(0.0, 1.0);
    final music = (musicVolume ?? 1.0).clamp(0.0, 1.0);
    return (master * music).clamp(0.0, 1.0);
  }

  factory StreamConfig.fromJson(Map<String, dynamic> json) {
    Logger.debug('Parsing StreamConfig from JSON: $json', 'StreamConfig');

    final streamUrl = json['stream_url'] ?? json['url'] ?? '';
    final streamUuid = json['stream_uuid'] as String?;
    final volume = _parseVolume(json['volume']);
    final parsedMusicVolume = _parseOptionalVolume(json['music_volume']);
    final title = json['title'];
    final description = json['description'];

    CurrentTrack? current;
    if (json['current'] != null) {
      current = CurrentTrack.fromJson(json['current']);
    }

    // TODO: DO NOT REMOVE!!!
    // final visualizerUrl = "http://localhost:3000/";

    final visualizerUrl = _parseOptionalUrl(
      json['visualizer_url'] ?? json['visualizerUrl'],
    );

    Logger.debug(
        'Parsed values - streamUrl: $streamUrl, volume: $volume, title: $title, description: $description, current: $current, visualizerUrl: $visualizerUrl',
        'StreamConfig');

    Logger.debug('📝 StreamConfig: Parsing JSON: $json', 'StreamConfig');
    Logger.debug('📝 StreamConfig: Found stream_url: ${json['stream_url']}',
        'StreamConfig');
    Logger.debug('📝 StreamConfig: Found url: ${json['url']}', 'StreamConfig');
    Logger.debug(
        '📝 StreamConfig: Final streamUrl: $streamUrl', 'StreamConfig');

    return StreamConfig(
      streamUrl: streamUrl,
      volume: volume,
      musicVolume: parsedMusicVolume,
      title: title,
      description: description,
      current: current,
      visualizerUrl: visualizerUrl,
      streamUuid: streamUuid,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'stream_url': streamUrl,
      if (streamUuid != null) 'stream_uuid': streamUuid,
      'volume': volume,
      if (musicVolume != null) 'music_volume': musicVolume,
      'title': title,
      'description': description,
      'current': current?.toJson(),
      if (visualizerUrl != null) 'visualizer_url': visualizerUrl,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StreamConfig &&
        other.streamUrl == streamUrl &&
        other.volume == volume &&
        other.musicVolume == musicVolume &&
        other.visualizerUrl == visualizerUrl &&
        other.title == title &&
        other.description == description &&
        other.current == current &&
        other.streamUuid == streamUuid;
  }

  @override
  int get hashCode => Object.hash(streamUrl, volume, musicVolume,
      visualizerUrl, title, description, current, streamUuid);

  static double _parseVolume(dynamic raw, [double defaultValue = 1.0]) {
    if (raw == null) return defaultValue;

    if (raw is num) {
      final value = raw.toDouble();
      if (value.isNaN) return defaultValue;
      return value.clamp(0.0, 1.0);
    }

    if (raw is String) {
      final parsed = double.tryParse(raw);
      if (parsed != null && !parsed.isNaN) {
        return parsed.clamp(0.0, 1.0);
      }
    }

    return defaultValue;
  }

  static double? _parseOptionalVolume(dynamic raw) {
    if (raw == null) return null;

    final parsed = _parseVolume(raw);
    return parsed;
  }

  // ignore: unused_element
  static String? _parseOptionalUrl(dynamic raw) {
    if (raw is! String || raw.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme.isEmpty) {
      return null;
    }

    return raw;
  }
}
