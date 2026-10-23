class Track {
  final String id;
  final String title;
  final String artist;
  final String album;
  final String duration;
  final String imageUrl;
  final String previewUrl;
  final bool isExplicit;

  bool get isPlayable => RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id);

  Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    required this.imageUrl,
    required this.previewUrl,
    this.isExplicit = false,
  });

  static const Set<String> _notArtists = {
    'mv', 'pv', 'official', 'lyrics', 'lyric', 'audio', 'hd', '4k', 'new', 'live',
    'cover', 'unreleased', 'leak', 'leaked', 'snippet', 'preview', 'full', 'ost',
  };

  /// "【Ado】新曲", "[Ado] Song", "Ado「Song」", "Ado - Song" -> (artist, title).
  static (String, String)? splitArtistTitle(String raw) {
    final s = raw.trim();
    final m = RegExp(r'^[【\[]([^】\]]{1,40})[】\]]\s*(.+)$').firstMatch(s) ??
        RegExp(r'^(.{1,40}?)\s+[-–—]\s+(.+)$').firstMatch(s) ??
        RegExp(r'^(.{1,40}?)\s*[「『](.+?)[」』]').firstMatch(s);
    if (m == null) return null;
    final artist = m.group(1)!.trim();
    final title = m.group(2)!.trim();
    if (artist.isEmpty || title.isEmpty || _notArtists.contains(artist.toLowerCase())) return null;
    return (artist, title);
  }

  factory Track.fromJson(Map<String, dynamic> json) {
    final rawTitle = (json['title'] ?? json['name'] ?? '').toString();
    String title = rawTitle;
    String artist = (json['artist'] ?? '').toString();
    if (artist.isEmpty) {
      final p = splitArtistTitle(rawTitle);
      if (p != null) {
        artist = p.$1;
        title = p.$2;
      }
    }
    return Track(
      id: (json['id'] ?? '').toString(),
      title: title,
      artist: artist,
      album: (json['album'] ?? '').toString(),
      duration: formatDuration(json['duration']),
      imageUrl: _thumbFor(
        (json['id'] ?? '').toString(),
        (json['imageUrl'] ?? json['thumb'] ?? '').toString(),
      ),
      previewUrl: (json['previewUrl'] ?? '').toString(),
      isExplicit: json['isExplicit'] == true,
    );
  }

  static String formatDuration(dynamic v) {
    if (v == null) return '0:00';
    if (v is String && v.contains(':')) return v;
    final s = v is num ? v.round() : int.tryParse('$v') ?? 0;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// The search backend can return a Piped proxy URL that answers 502.
  /// The id-based YouTube thumbnail is always available.
  static String _thumbFor(String id, String fallback) {
    if (RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(id)) {
      return 'https://i.ytimg.com/vi/$id/mqdefault.jpg';
    }
    return fallback;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'album': album,
      'duration': duration,
      'imageUrl': imageUrl,
      'previewUrl': previewUrl,
      'isExplicit': isExplicit,
    };
  }
}
