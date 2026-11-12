class CurrentTrack {
  final String artist;
  final String title;
  final String uuid;
  final int duration;
  final bool isMusic;
  final String url;

  /// Cover art for the track. For the station's own items (jingles,
  /// announcements) the backend sends the station cover here when the item has
  /// none of its own.
  final String? artworkUrl;

  const CurrentTrack({
    required this.artist,
    required this.title,
    required this.uuid,
    required this.duration,
    required this.isMusic,
    required this.url,
    this.artworkUrl,
  });

  factory CurrentTrack.fromJson(Map<String, dynamic> json) {
    return CurrentTrack(
      artist: json['artist']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      uuid: json['uuid']?.toString() ?? '',
      duration: json['duration'] is num ? (json['duration'] as num).toInt() : 0,
      isMusic: json['is_music'] == true,
      url: json['url']?.toString() ?? '',
      artworkUrl: _nonEmpty(json['artwork_url']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'artist': artist,
      'title': title,
      'uuid': uuid,
      'duration': duration,
      'is_music': isMusic,
      'url': url,
      if (artworkUrl != null) 'artwork_url': artworkUrl,
    };
  }

  static String? _nonEmpty(dynamic raw) {
    final value = raw?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  String get fileName => '$uuid.m4a';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CurrentTrack && other.uuid == uuid;
  }

  @override
  int get hashCode => uuid.hashCode;

  @override
  String toString() {
    return 'CurrentTrack(artist: $artist, title: $title, uuid: $uuid, duration: $duration, isMusic: $isMusic)';
  }
}
