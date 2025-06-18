class StreamConfig {
  final String streamUrl;
  final double volume;
  final String? title;
  final String? description;

  StreamConfig({
    required this.streamUrl,
    this.volume = 1.0,
    this.title,
    this.description,
  });

  factory StreamConfig.fromJson(Map<String, dynamic> json) {
    return StreamConfig(
      streamUrl: json['stream_url'] ?? json['url'] ?? '',
      volume: (json['volume'] ?? 1.0).toDouble(),
      title: json['title'],
      description: json['description'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'stream_url': streamUrl,
      'volume': volume,
      'title': title,
      'description': description,
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
