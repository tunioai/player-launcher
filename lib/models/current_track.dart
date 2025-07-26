class CurrentTrack {
  final String artist;
  final String title;
  final String uuid;
  final int duration;
  final bool isMusic;
  final String url;

  const CurrentTrack({
    required this.artist,
    required this.title,
    required this.uuid,
    required this.duration,
    required this.isMusic,
    required this.url,
  });

  factory CurrentTrack.fromJson(Map<String, dynamic> json) {
    return CurrentTrack(
      artist: json['artist'] ?? '',
      title: json['title'] ?? '',
      uuid: json['uuid'] ?? '',
      duration: json['duration'] ?? 0,
      isMusic: json['is_music'] ?? false,
      url: json['url'] ?? '',
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
    };
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
