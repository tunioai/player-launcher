import '../utils/logger.dart';
import 'current_track.dart';

class StreamConfig {
  final String streamUrl;
  final double volume;
  final String? title;
  final String? description;
  final CurrentTrack? current;

  const StreamConfig({
    required this.streamUrl,
    this.volume = 1.0,
    this.title,
    this.description,
    this.current,
  });

  factory StreamConfig.fromJson(Map<String, dynamic> json) {
    Logger.debug('Parsing StreamConfig from JSON: $json', 'StreamConfig');

    final streamUrl = json['stream_url'] ?? json['url'] ?? '';
    final volume = (json['volume'] ?? 1.0).toDouble();
    final title = json['title'];
    final description = json['description'];
    
    CurrentTrack? current;
    if (json['current'] != null) {
      current = CurrentTrack.fromJson(json['current']);
    }

    Logger.debug(
        'Parsed values - streamUrl: $streamUrl, volume: $volume, title: $title, description: $description, current: $current',
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
      title: title,
      description: description,
      current: current,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'stream_url': streamUrl,
      'volume': volume,
      'title': title,
      'description': description,
      'current': current?.toJson(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is StreamConfig &&
        other.streamUrl == streamUrl &&
        other.volume == volume;
  }

  @override
  int get hashCode => streamUrl.hashCode ^ volume.hashCode;
}
