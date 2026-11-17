import 'package:flutter/foundation.dart';
import '../models/track_model.dart';
import 'artist_credit.dart';
import 'youtube_api.dart';

class _Row {
  final Track track;
  final List<String> artistIds;
  const _Row(this.track, this.artistIds);
}

class _Pager {
  final String query;
  final List<Track> tracks = <Track>[];
  final Set<String> seen = <String>{};
  String token = '';
  bool done = false;
  int pages = 0;
  DateTime used = DateTime.now();
  Future<void> _tail = Future<void>.value();

  _Pager(this.query);

  Future<void> exclusive(Future<void> Function() job) {
    final next = _tail.then((_) => job());
    _tail = next.catchError((Object _) {});
    return next;
  }
}

class YouTubeCatalog {
  YouTubeCatalog._();

  static const String _videoFilter = 'EgIQAQ%3D%3D';
  static const String _songFilter = 'EgWKAQIIAWoMEA4QChADEAQQCRAF';
  static const String _artistFilter = 'EgWKAQIgAWoMEA4QChADEAQQCRAF';
  static const int _maxPages = 4;
  static const int _keepPagers = 12;
  static const Duration _pagerLife = Duration(minutes: 10);

  static final RegExp _idRe = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  static final RegExp _durationRe = RegExp(r'^\d{1,2}(?::\d{2}){1,2}$');
  static final RegExp _notArtist = RegExp(
    r'^(?:song|video|single|album|ep|playlist|artist)$|'
    r'\d[\d.,]*\s*[KMB]?\s*(?:views?|plays?|subscribers?|likes?)\b',
    caseSensitive: false,
  );

  static final Map<String, _Pager> _pagers = <String, _Pager>{};

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static _Pager _pagerFor(String query) {
    final now = DateTime.now();
    _pagers.removeWhere((_, p) => now.difference(p.used) > _pagerLife);
    final key = query.toLowerCase();
    var pager = _pagers.remove(key);
    pager ??= _Pager(query);
    pager.used = now;
    _pagers[key] = pager;
    while (_pagers.length > _keepPagers) {
      _pagers.remove(_pagers.keys.first);
    }
    return pager;
  }

  static Future<List<Track>> search(String query, {int limit = 25}) async {
    final q = query.trim();
    if (q.isEmpty) return const <Track>[];
    final pager = _pagerFor(q);
    await pager.exclusive(() async {
      try {
        while (pager.tracks.length < limit && !pager.done && pager.pages < _maxPages) {
          await _fetchPage(pager);
        }
      } catch (_) {
        if (pager.tracks.isEmpty) rethrow;
      }
    });
    if (pager.tracks.isEmpty) _pagers.remove(q.toLowerCase());
    return pager.tracks.length > limit
        ? pager.tracks.sublist(0, limit)
        : List<Track>.of(pager.tracks);
  }

  static Future<void> _fetchPage(_Pager p) async {
    final first = p.pages == 0;
    final data = await YouTubeApi.post('search', <String, Object?>{
      if (first) 'query': p.query else 'continuation': p.token,
      if (first) 'params': _videoFilter,
    });
    p.pages++;
    p.token = YtJson.continuation(data);
    if (p.token.isEmpty) p.done = true;
    for (final v in YtJson.all(data, 'videoRenderer')) {
      final t = _video(v);
      if (t != null && p.seen.add(t.id)) p.tracks.add(t);
    }
  }

  static Track? _video(Map<String, dynamic> v) {
    final id = YtJson.str(v['videoId']);
    if (!_idRe.hasMatch(id)) return null;
    final secs = YtJson.seconds(YtJson.text(v['lengthText']));
    if (secs <= 0 || secs > 900) return null;
    final title = YtJson.text(v['title']).trim();
    if (title.isEmpty) return null;
    return Track.fromJson(<String, dynamic>{'id': id, 'title': title, 'duration': secs});
  }

  static Future<List<Track>> songs(String query, {int limit = 10}) async {
    final rows = await _songRows(query);
    return <Track>[for (final r in rows.take(limit)) r.track];
  }

  static Future<List<_Row>> _songRows(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const <_Row>[];
    final data = await YouTubeApi.post(
      'search',
      <String, Object?>{'query': q, 'params': _songFilter},
      surface: YouTubeSurface.music,
    );
    return _rows(data);
  }

  static List<_Row> _rows(Map<String, dynamic> data) {
    final out = <_Row>[];
    final seen = <String>{};
    for (final r in YtJson.all(data, 'musicResponsiveListItemRenderer')) {
      final row = _song(r);
      if (row != null && seen.add(row.track.id)) out.add(row);
    }
    return out;
  }

  static Future<List<({String id, String name})>> _artistHits(String name) async {
    final data = await YouTubeApi.post(
      'search',
      <String, Object?>{'query': name, 'params': _artistFilter},
      surface: YouTubeSurface.music,
    );
    final out = <({String id, String name})>[];
    for (final r in YtJson.all(data, 'musicResponsiveListItemRenderer')) {
      final id = YtJson.browseId(r);
      if (!id.startsWith('UC')) continue;
      final title = _plain(_flex(r, 0)).trim();
      if (title.isEmpty) continue;
      out.add((id: id, name: title));
    }
    return out;
  }

  static Future<List<_Row>> _artistPage(String artistId) async {
    final page = await YouTubeApi.post(
      'browse',
      <String, Object?>{'browseId': artistId},
      surface: YouTubeSurface.music,
    );
    final top = _rows(page);
    var more = '';
    for (final shelf in YtJson.all(page, 'musicShelfRenderer')) {
      final titled = YtJson.browseId(YtJson.runs(shelf['title']).firstOrNull);
      final bottom = YtJson.str(
          YtJson.map(YtJson.map(shelf['bottomEndpoint'])?['browseEndpoint'])?['browseId']);
      more = titled.isNotEmpty ? titled : bottom;
      if (more.isNotEmpty) break;
    }
    if (more.isEmpty) return top;
    try {
      final all = await YouTubeApi.post(
        'browse',
        <String, Object?>{'browseId': more},
        surface: YouTubeSurface.music,
      );
      final rows = _rows(all);
      if (rows.isNotEmpty) return rows;
    } catch (e) {
      debugPrint('YouTube Music: full song list failed: $e');
    }
    return top;
  }

  static Future<List<_Row>> _radio(String videoId) async {
    final data = await YouTubeApi.post(
      'next',
      <String, Object?>{
        'videoId': videoId,
        'playlistId': 'RDAMVM$videoId',
        'isAudioOnly': true,
      },
      surface: YouTubeSurface.music,
    );
    final out = <_Row>[];
    final seen = <String>{videoId};
    final panels =
        YtJson.all(data, 'playlistPanelVideoRenderer', skip: const <String>{'counterpart'});
    for (final p in panels) {
      final row = _panel(p);
      if (row != null && seen.add(row.track.id)) out.add(row);
    }
    return out;
  }

  static Future<List<Track>> related(String videoId, {int limit = 30}) async {
    if (!_idRe.hasMatch(videoId)) return const <Track>[];
    final data = await YouTubeApi.post('next', <String, Object?>{
      'videoId': videoId,
      'playlistId': 'RD$videoId',
    });
    final out = <Track>[];
    final seen = <String>{videoId};
    final panels =
        YtJson.all(data, 'playlistPanelVideoRenderer', skip: const <String>{'counterpart'});
    for (final p in panels) {
      final id = YtJson.str(p['videoId']);
      final title = YtJson.text(p['title']).trim();
      if (!_idRe.hasMatch(id) || title.isEmpty || !seen.add(id)) continue;
      final secs = YtJson.seconds(YtJson.text(p['lengthText']));
      out.add(Track.fromJson(<String, dynamic>{
        'id': id,
        'title': title,
        'duration': secs > 0 ? secs : null,
      }));
    }
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  static Future<List<Track>> similar(
    String videoId, {
    String query = '',
    String artist = '',
    int limit = 25,
  }) async {
    final out = <Track>[];
    final seen = <String>{videoId};

    void add(Track t) {
      if (t.id.isEmpty || !seen.add(t.id)) return;
      out.add(t);
    }

    var hits = const <_Row>[];
    if (query.isNotEmpty) {
      try {
        hits = await _songRows(query);
      } catch (e) {
        debugPrint('YouTube Music: song search for "$query" failed: $e');
      }
    }
    final anchor = _anchor(hits, query);
    if (anchor != null) seen.add(anchor.track.id);

    try {
      for (final r in await _radio(anchor?.track.id ?? videoId)) {
        add(r.track);
      }
    } catch (e) {
      debugPrint('YouTube Music: radio failed: $e');
    }

    String? artistId = (anchor == null || anchor.artistIds.isEmpty) ? null : anchor.artistIds.first;
    if (anchor == null && artist.isNotEmpty && out.length < 10) {
      try {
        final want = _norm(artist);
        for (final h in await _artistHits(artist)) {
          if (_norm(h.name) != want) continue;
          artistId = h.id;
          break;
        }
      } catch (e) {
        debugPrint('YouTube Music: artist search for "$artist" failed: $e');
      }
    }

    final owner = artistId;
    if (out.length < 10 && owner != null) {
      try {
        for (final r in await _artistPage(owner)) {
          if (r.artistIds.isNotEmpty && !r.artistIds.contains(owner)) continue;
          add(_withArtist(r.track, anchor?.track.artist ?? artist));
        }
      } catch (e) {
        debugPrint('YouTube Music: songs of the artist failed: $e');
      }
    }

    if (out.length < 5) {
      for (final r in hits) {
        final same = anchor != null
            ? _sameArtist(r, anchor)
            : _inQuery(r.track.artist, query);
        if (same) add(r.track);
      }
    }
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  static Future<List<Track>> artistSongs(String name, {int limit = 25}) async {
    final want = _norm(name);
    if (want.isEmpty) return const <Track>[];
    String? artistId;
    var spelled = name;
    var answered = false;
    Object? failure;
    try {
      for (final h in await _artistHits(name)) {
        if (_norm(h.name) != want) continue;
        artistId = h.id;
        spelled = h.name;
        break;
      }
      answered = true;
    } catch (e) {
      failure = e;
      debugPrint('YouTube Music: artist search for "$name" failed: $e');
    }
    if (answered && artistId == null) return const <Track>[];

    final id = artistId;
    final label = spelled;
    final out = <Track>[];
    final seen = <String>{};

    void add(List<_Row> rows, bool fromSearch) {
      for (final r in rows) {
        if (seen.contains(r.track.id) || !_belongs(r, id, name, fromSearch)) continue;
        seen.add(r.track.id);
        out.add(_withArtist(r.track, label));
      }
    }

    if (id != null) {
      try {
        add(await _artistPage(id), false);
        answered = true;
      } catch (e) {
        failure = e;
        debugPrint('YouTube Music: songs of "$name" failed: $e');
      }
    }
    if (out.length < 10) {
      try {
        add(await _songRows(name), true);
        answered = true;
      } catch (e) {
        failure = e;
        debugPrint('YouTube Music: song search for "$name" failed: $e');
      }
    }
    final error = failure;
    if (out.isEmpty && !answered && error != null) throw error;
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  static Future<List<({String artist, String name})>> trending({int limit = 16}) async {
    var best = const <({String artist, String name})>[];
    for (final page in const <String>['FEmusic_charts', 'FEmusic_explore']) {
      try {
        final data = await YouTubeApi.post(
          'browse',
          <String, Object?>{
            'browseId': page,
            if (page == 'FEmusic_charts')
              'formData': <String, Object?>{
                'selectedValues': <String>['ZZ'],
              },
          },
          surface: YouTubeSurface.music,
        );
        final found = _chart(data);
        if (found.length > best.length) best = found;
        if (best.length >= limit) break;
      } catch (e) {
        debugPrint('YouTube Music: $page failed: $e');
      }
    }
    return best.length > limit ? best.sublist(0, limit) : best;
  }

  static List<({String artist, String name})> _chart(Map<String, dynamic> data) {
    final out = <({String artist, String name})>[];
    final seen = <String>{};
    final items = YtJson.allOf(
      data,
      const <String>{'musicResponsiveListItemRenderer', 'musicTwoRowItemRenderer'},
    );
    for (final item in items) {
      String id = '';
      String title = '';
      String artist = '';
      if (item.containsKey('flexColumns')) {
        final row = _song(item);
        if (row == null) continue;
        id = row.track.id;
        title = row.track.title;
        artist = row.track.artist;
      } else {
        final watch = YtJson.map(YtJson.map(item['navigationEndpoint'])?['watchEndpoint']);
        id = YtJson.str(watch?['videoId']);
        title = YtJson.text(item['title']).trim();
        final runs = YtJson.runs(item['subtitle']);
        artist = _credit(runs).artist;
        if (artist.isEmpty) artist = _lead(runs);
      }
      if (!_idRe.hasMatch(id) || title.isEmpty || artist.trim().isEmpty) continue;
      if (!seen.add(id) || !seen.add('${_norm(artist)}|${_norm(title)}')) continue;
      out.add((artist: artist.trim(), name: title));
    }
    return out;
  }

  static List<Map<String, dynamic>> _flex(Map<String, dynamic> r, int i) {
    final cols = YtJson.list(r['flexColumns']);
    if (i >= cols.length) return const <Map<String, dynamic>>[];
    final col = YtJson.map(YtJson.map(cols[i])?['musicResponsiveListItemFlexColumnRenderer']);
    return YtJson.runs(col?['text']);
  }

  static String _plain(List<Map<String, dynamic>> runs) {
    final b = StringBuffer();
    for (final r in runs) {
      b.write(YtJson.str(r['text']));
    }
    return b.toString();
  }

  static String _lead(List<Map<String, dynamic>> runs) {
    final b = StringBuffer();
    for (final r in runs) {
      final t = YtJson.str(r['text']);
      if (t.trim() == '•') break;
      b.write(t);
    }
    final lead = b.toString().trim();
    if (lead.isEmpty || _notArtist.hasMatch(lead) || _durationRe.hasMatch(lead)) return '';
    return lead;
  }

  static ({String artist, List<String> ids}) _credit(List<Map<String, dynamic>> runs) {
    final names = <String>[];
    final ids = <String>[];
    final seen = <String>{};
    for (final r in runs) {
      final id = YtJson.browseId(r);
      if (!id.startsWith('UC')) continue;
      final name = YtJson.str(r['text']).trim();
      if (name.isEmpty || !seen.add(id)) continue;
      names.add(name);
      ids.add(id);
    }
    return (artist: names.join(', '), ids: ids);
  }

  static ({String artist, List<String> ids, String album, int seconds}) _meta(
    List<Map<String, dynamic>> runs,
  ) {
    final credit = _credit(runs);
    var artist = credit.artist;
    if (artist.isEmpty) artist = _lead(runs);
    var album = '';
    var seconds = 0;
    for (final r in runs) {
      final t = YtJson.str(r['text']).trim();
      if (album.isEmpty && YtJson.browseId(r).startsWith('MPRE')) album = t;
      if (_durationRe.hasMatch(t)) seconds = YtJson.seconds(t);
    }
    return (artist: artist, ids: credit.ids, album: album, seconds: seconds);
  }

  static String _videoIdIn(Map<String, dynamic> r) {
    final direct = YtJson.str(YtJson.map(r['playlistItemData'])?['videoId']);
    if (direct.isNotEmpty) return direct;
    for (final w in YtJson.all(r, 'watchEndpoint')) {
      final id = YtJson.str(w['videoId']);
      if (id.isNotEmpty) return id;
    }
    return '';
  }

  static bool _explicit(Map<String, dynamic> r) {
    for (final b in YtJson.list(r['badges'])) {
      final badge = YtJson.map(YtJson.map(b)?['musicInlineBadgeRenderer']);
      final icon = YtJson.map(badge?['icon']);
      if (YtJson.str(icon?['iconType']) == 'MUSIC_EXPLICIT_BADGE') return true;
    }
    return false;
  }

  static int _fixedSeconds(Map<String, dynamic> r) {
    for (final c in YtJson.list(r['fixedColumns'])) {
      final col = YtJson.map(YtJson.map(c)?['musicResponsiveListItemFixedColumnRenderer']);
      final s = YtJson.seconds(YtJson.text(col?['text']));
      if (s > 0) return s;
    }
    return 0;
  }

  static _Row? _song(Map<String, dynamic> r) {
    final id = _videoIdIn(r);
    if (!_idRe.hasMatch(id)) return null;
    final title = _plain(_flex(r, 0)).trim();
    if (title.isEmpty) return null;
    final runs = <Map<String, dynamic>>[];
    for (var i = 1; i < 4; i++) {
      final col = _flex(r, i);
      if (col.isEmpty) continue;
      if (runs.isNotEmpty) runs.add(const <String, dynamic>{'text': ' • '});
      runs.addAll(col);
    }
    final meta = _meta(runs);
    final seconds = meta.seconds > 0 ? meta.seconds : _fixedSeconds(r);
    return _Row(
      Track.fromJson(<String, dynamic>{
        'id': id,
        'title': title,
        'artist': meta.artist,
        'album': meta.album,
        'duration': seconds > 0 ? seconds : null,
        'isExplicit': _explicit(r),
      }),
      meta.ids,
    );
  }

  static _Row? _panel(Map<String, dynamic> p) {
    final id = YtJson.str(p['videoId']);
    if (!_idRe.hasMatch(id)) return null;
    final title = YtJson.text(p['title']).trim();
    if (title.isEmpty) return null;
    var runs = YtJson.runs(p['longBylineText']);
    if (runs.isEmpty) runs = YtJson.runs(p['shortBylineText']);
    final meta = _meta(runs);
    final seconds = YtJson.seconds(YtJson.text(p['lengthText']));
    return _Row(
      Track.fromJson(<String, dynamic>{
        'id': id,
        'title': title,
        'artist': meta.artist,
        'album': meta.album,
        'duration': seconds > 0 ? seconds : null,
        'isExplicit': _explicit(p),
      }),
      meta.ids,
    );
  }

  static Track _withArtist(Track t, String artist) {
    if (t.artist.trim().isNotEmpty || artist.trim().isEmpty) return t;
    return Track(
      id: t.id,
      title: t.title,
      artist: artist,
      album: t.album,
      duration: t.duration,
      imageUrl: t.imageUrl,
      previewUrl: t.previewUrl,
      isExplicit: t.isExplicit,
    );
  }

  static bool _inQuery(String artist, String query) {
    final q = _norm(query);
    for (final n in ArtistCredit.parse(artist).names) {
      final k = _norm(n);
      if (k.length >= 2 && q.contains(k)) return true;
    }
    return false;
  }

  static _Row? _anchor(List<_Row> rows, String query) {
    final nq = _norm(query);
    if (nq.isEmpty) return null;
    _Row? best;
    var bestScore = 0;
    for (final r in rows) {
      final t = _norm(r.track.title);
      if (t.length < 3 || !nq.contains(t)) continue;
      final hasArtist = _inQuery(r.track.artist, query);
      if (!hasArtist && t.length * 2 < nq.length) continue;
      final score = t.length + (hasArtist ? 100 : 0);
      if (score > bestScore) {
        best = r;
        bestScore = score;
      }
    }
    return best;
  }

  static bool _sameArtist(_Row a, _Row b) {
    if (a.artistIds.isNotEmpty && b.artistIds.isNotEmpty) {
      return a.artistIds.first == b.artistIds.first;
    }
    return _norm(a.track.artist) == _norm(b.track.artist);
  }

  static bool _belongs(_Row r, String? id, String name, bool fromSearch) {
    if (id != null) {
      return r.artistIds.isNotEmpty ? r.artistIds.contains(id) : !fromSearch;
    }
    return ArtistCredit.parse(r.track.artist).has(name);
  }
}
