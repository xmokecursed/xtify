import '../models/track_model.dart';
import 'playlist_source.dart';
import 'youtube_api.dart';

class YouTubePlaylistReader {
  YouTubePlaylistReader._();

  static const int _maxPages = 300;
  static const String _unavailable = 'Private, deleted or unavailable video';

  static final RegExp _idRe = RegExp(r'^[a-zA-Z0-9_-]{11}$');

  static Future<SourcePlaylist> read(
    String id, {
    void Function(int found)? onProgress,
  }) async {
    final songs = <SourceSong>[];
    var title = '';
    var note = '';
    var token = '';
    var pages = 0;
    while (pages < _maxPages) {
      Map<String, dynamic> data;
      try {
        data = await YouTubeApi.post('browse', <String, Object?>{
          if (pages == 0) 'browseId': 'VL$id' else 'continuation': token,
        });
      } catch (e) {
        if (pages == 0) throw SourceException(_reason(e));
        note = 'YouTube stopped answering, so the rest of the playlist was not read.';
        break;
      }
      pages++;
      final items = YtJson.all(data, 'playlistVideoRenderer');
      if (pages == 1) {
        title = _title(data);
        if (items.isEmpty) throw SourceException(_problem(data));
      }
      for (final item in items) {
        songs.add(_song(item));
      }
      onProgress?.call(songs.length);
      token = YtJson.continuation(data);
      if (token.isEmpty) break;
    }
    return SourcePlaylist(
      title: title.isEmpty ? 'YouTube playlist' : title,
      songs: songs,
      note: note,
    );
  }

  static String _reason(Object e) {
    if (e is YouTubeApiException && e.throttled) {
      return 'YouTube is limiting requests right now. Try again in a few minutes.';
    }
    return 'Could not read this playlist from YouTube. Check your connection.';
  }

  static String _title(Map<String, dynamic> data) {
    final meta = YtJson.map(YtJson.map(data['metadata'])?['playlistMetadataRenderer']);
    final fromMeta = YtJson.str(meta?['title']).trim();
    if (fromMeta.isNotEmpty) return fromMeta;
    for (final header in YtJson.all(data, 'playlistHeaderRenderer')) {
      final t = YtJson.text(header['title']).trim();
      if (t.isNotEmpty) return t;
    }
    return '';
  }

  static String _problem(Map<String, dynamic> data) {
    for (final alert in YtJson.all(data, 'alertRenderer')) {
      final t = YtJson.text(alert['text']).trim();
      if (t.isNotEmpty) return t;
    }
    return 'This playlist is empty, private or does not exist.';
  }

  static String _channel(String raw) => raw
      .replaceAll(RegExp(r'\s*-\s*topic$', caseSensitive: false), '')
      .replaceAll(RegExp(r'vevo$', caseSensitive: false), '')
      .trim();

  static SourceSong _song(Map<String, dynamic> item) {
    final id = YtJson.str(item['videoId']);
    final title = YtJson.text(item['title']).trim();
    final playable = item['isPlayable'] != false &&
        title != '[Private video]' &&
        title != '[Deleted video]';
    if (!_idRe.hasMatch(id) || !playable) {
      return SourceSong(
        title: title.isEmpty ? 'Unavailable video' : title,
        problem: _unavailable,
      );
    }
    var seconds = int.tryParse(YtJson.str(item['lengthSeconds'])) ?? 0;
    if (seconds <= 0) seconds = YtJson.seconds(YtJson.text(item['lengthText']));
    final channel = Track.splitArtistTitle(title) == null
        ? _channel(YtJson.text(item['shortBylineText']))
        : '';
    return SourceSong(title: title, artist: channel, seconds: seconds, videoId: id);
  }
}
