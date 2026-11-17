import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'playlist_source.dart';

class SpotifyReader {
  SpotifyReader._();

  static const int shareLimit = 100;

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/149.0.0.0 Safari/537.36';

  static final RegExp _data = RegExp(
    r'<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>',
    dotAll: true,
  );

  static Future<SourcePlaylist> read(String id) async {
    final page = await _download('https://open.spotify.com/embed/playlist/$id');
    final match = _data.firstMatch(page);
    final entity = match == null ? null : _entity(_decode(match.group(1)!));
    if (entity == null) {
      throw const SourceException(
        'Spotify did not share this playlist. It may be private or removed.',
      );
    }
    final songs = <SourceSong>[];
    for (final raw in entity['trackList'] as List<dynamic>) {
      if (raw is! Map<String, dynamic>) continue;
      final uri = _text(raw['uri']);
      if (uri.startsWith('spotify:episode:')) continue;
      final title = _text(raw['title']);
      if (title.isEmpty) continue;
      final ms = raw['duration'];
      songs.add(SourceSong(
        title: title,
        artist: _text(raw['subtitle']),
        seconds: ms is num ? (ms / 1000).round() : 0,
      ));
    }
    if (songs.isEmpty) {
      throw const SourceException('Spotify shares no songs from this playlist.');
    }
    final name = _text(entity['name']);
    final title = name.isNotEmpty ? name : _text(entity['title']);
    final total = _count(entity);
    final hidden = total > songs.length ? total - songs.length : 0;
    var note = '';
    if (hidden > 0) {
      note = 'Spotify shares only the first ${songs.length} of $total songs in a '
          'playlist link, so $hidden songs were not imported.';
    } else if (songs.length >= shareLimit) {
      note = 'Spotify shares at most $shareLimit songs in a playlist link. If this '
          'playlist has more, the rest were not imported.';
    }
    return SourcePlaylist(
      title: title.isEmpty ? 'Spotify playlist' : title,
      songs: songs,
      hidden: hidden,
      note: note,
    );
  }

  static String _text(Object? v) =>
      v is String ? v.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim() : '';

  static int _count(Map<String, dynamic> entity) {
    for (final key in const <String>['trackCount', 'totalTracks', 'total']) {
      final v = entity[key];
      if (v is num && v > 0) return v.toInt();
    }
    return 0;
  }

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _entity(Object? node) {
    if (node is Map<String, dynamic>) {
      if (node['trackList'] is List<dynamic>) return node;
      for (final v in node.values) {
        final found = _entity(v);
        if (found != null) return found;
      }
    } else if (node is List<dynamic>) {
      for (final v in node) {
        final found = _entity(v);
        if (found != null) return found;
      }
    }
    return null;
  }

  static Future<String> _download(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 15));
      req.headers
        ..set(HttpHeaders.userAgentHeader, _userAgent)
        ..set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml')
        ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode == 404) {
        await res.drain<void>();
        throw const SourceException(
          'Spotify could not find this playlist. It may be private or removed.',
        );
      }
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw SourceException('Spotify answered HTTP ${res.statusCode}.');
      }
      return await res
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 30));
    } on SourceException {
      rethrow;
    } on TimeoutException {
      throw const SourceException('Spotify took too long to answer.');
    } catch (_) {
      throw const SourceException('Could not reach Spotify. Check your connection.');
    } finally {
      client.close(force: true);
    }
  }
}
