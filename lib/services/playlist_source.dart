enum PlaylistSource { spotify, youtube }

class SourceException implements Exception {
  final String message;
  const SourceException(this.message);

  @override
  String toString() => message;
}

class SourceSong {
  final String title;
  final String artist;
  final int seconds;
  final String videoId;
  final String problem;

  const SourceSong({
    required this.title,
    this.artist = '',
    this.seconds = 0,
    this.videoId = '',
    this.problem = '',
  });

  String get label => artist.isEmpty ? title : '$artist - $title';
}

class SourcePlaylist {
  final String title;
  final List<SourceSong> songs;
  final int hidden;
  final String note;

  const SourcePlaylist({
    required this.title,
    required this.songs,
    this.hidden = 0,
    this.note = '',
  });
}

class PlaylistLink {
  final PlaylistSource source;
  final String id;

  const PlaylistLink(this.source, this.id);

  String get key => '${source.name}:$id';

  String get sourceName => source == PlaylistSource.spotify ? 'Spotify' : 'YouTube';

  static final RegExp _spotifyUrl = RegExp(
    r'open\.spotify\.com/(?:intl-[A-Za-z-]+/)?(?:user/[^/?#\s]+/)?playlist/([A-Za-z0-9]{22})',
  );
  static final RegExp _spotifyUri =
      RegExp(r'spotify:(?:user:[^:\s]+:)?playlist:([A-Za-z0-9]{22})');
  static final RegExp _youtubeList = RegExp(r'[?&]list=([A-Za-z0-9_-]+)');

  static List<PlaylistLink> findAll(String text) {
    final out = <PlaylistLink>[];
    final seen = <String>{};
    for (final raw in text.split(RegExp(r'[\s,;]+'))) {
      final link = _one(raw.trim());
      if (link != null && seen.add(link.key)) out.add(link);
    }
    return out;
  }

  static PlaylistLink? _one(String token) {
    if (token.isEmpty) return null;
    final spotify = _spotifyUrl.firstMatch(token) ?? _spotifyUri.firstMatch(token);
    if (spotify != null) return PlaylistLink(PlaylistSource.spotify, spotify.group(1)!);
    if (!token.contains('youtube.com') && !token.contains('youtu.be')) return null;
    final id = _youtubeList.firstMatch(token)?.group(1);
    if (id == null || id.length < 10 || id.startsWith('RD')) return null;
    return PlaylistLink(PlaylistSource.youtube, id);
  }
}
