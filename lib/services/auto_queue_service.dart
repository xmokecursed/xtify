import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/track_model.dart';
import 'api_service.dart';
import 'artist_credit.dart';
import 'auto_queue_settings.dart';
import 'history_service.dart';

class _Candidate {
  final String artist;
  final String name;
  final Track? ready;
  const _Candidate(this.artist, this.name, [this.ready]);
  String get key => '${artist.toLowerCase()}|${name.toLowerCase()}';
}

enum _ArtistPool {
  ready,
  none,
  failed,
}

class AutoQueueService {
  final Random _rng = Random();
  final AutoQueueSettings _settings = AutoQueueSettings.instance;
  final Set<String> _usedIds = {};
  final Set<String> _usedKeys = {};
  final Set<String> _playedIds = {};
  final Set<String> _playedTitles = {};
  List<_Candidate> _pool = [];
  String? _poolSeedId;
  String? _loadedFor;
  Future<void>? _poolLoading;
  Future<Track?>? _nextFuture;
  int _epoch = 0;
  final Set<String> _ytmTried = {};
  final Map<String, int> _retries = {};

  String? _wanted;
  bool _artistOk = true;
  final Set<String> _artistIds = {};
  final List<Track> _recent = [];
  List<_Candidate> _source = const [];
  String _sourceFor = '';
  DateTime _sourceAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _sourceTtl = Duration(minutes: 30);

  static final RegExp _junk = RegExp(
    r'\b(cover|karaoke|reaction|tutorial|nightcore|slowed|sped up|8d)\b',
    caseSensitive: false,
  );

  static String cleanTitle(String s) {
    var t = s;
    t = t.replaceAll(
      RegExp(
        r'\s*[\(\[][^\)\]]*(official|video|audio|lyrics?|visuali[sz]er|remaster|hd|4k|explicit|mv)[^\)\]]*[\)\]]',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(
      RegExp(r'\s*[\(\[]?\b(?:ft|feat|featuring)\b\.?\s.*$', caseSensitive: false),
      '',
    );
    t = t.replaceAll(RegExp(r'\s*\|.*$'), '');
    return t.trim();
  }

  void _reset() {
    _epoch++;
    _pool = [];
    _poolSeedId = null;
    _loadedFor = null;
    _poolLoading = null;
    _nextFuture = null;
    _ytmTried.clear();
  }

  void startSession(Track seed, {String? searchedFor}) {
    _reset();
    _usedIds
      ..clear()
      ..add(seed.id);
    _usedKeys
      ..clear()
      ..add(_Candidate(seed.artist, cleanTitle(seed.title)).key);
    _playedIds
      ..clear()
      ..add(seed.id);
    _playedTitles
      ..clear()
      ..add(_titleKey(seed.title));
    _settings.begin(searchedFor);
    _artistOk = true;
    _artistIds.clear();
    _recent.clear();
    _remember(seed);
  }

  void restart() {
    _reset();
    _artistOk = true;
  }

  static String _titleKey(String title) => _norm(cleanTitle(title));

  bool _alreadyPlayed(Track t) =>
      _playedIds.contains(t.id) || _playedTitles.contains(_titleKey(t.title));

  void advanced(Track t) {
    _usedIds.add(t.id);
    _usedKeys.add(_Candidate(t.artist, cleanTitle(t.title)).key);
    _playedIds.add(t.id);
    _playedTitles.add(_titleKey(t.title));
    _remember(t);
  }

  void _remember(Track t) {
    _recent.removeWhere((x) => x.id == t.id);
    _recent.add(t);
    if (_recent.length > 6) _recent.removeAt(0);
  }

  String? focusFor(Track seed) {
    if (_settings.mode.value != AutoQueueMode.sameArtist) return null;
    if (!_artistOk) return _wanted;
    if (!(_artistIds.contains(seed.id) && _settings.focus.value != null)) {
      _settings.follow(seed);
    }
    return _settings.focus.value?.name;
  }

  void _syncPool(Track seed) {
    final want = focusFor(seed);
    if (want == _wanted) return;
    _reset();
    _wanted = want;
    _artistOk = true;
  }

  Future<void> warm(Track seed) async {
    _syncPool(seed);
    final epoch = _epoch;
    await _ensurePool(seed);
    if (epoch != _epoch) return;
    _nextFuture ??= _choose();
  }

  Future<Track?> nextFor(Track seed) async {
    _syncPool(seed);
    final epoch = _epoch;
    await _ensurePool(seed);
    if (epoch != _epoch) return null;
    final f = _nextFuture ?? _choose();
    _nextFuture = null;
    var t = await f;
    if (t == null && epoch == _epoch && _pool.isNotEmpty) t = await _choose();
    for (var i = 0; t != null && _alreadyPlayed(t) && i < 3; i++) {
      debugPrint('auto-queue: dropped "${t.title}" (${t.id}), it already played');
      if (epoch != _epoch) return null;
      t = await _choose();
    }
    if (t != null && _alreadyPlayed(t)) return null;
    return epoch == _epoch ? t : null;
  }

  Future<void> _ensurePool(Track seed) {
    if (_loadedFor == seed.id || (_loadedFor != null && _pool.length >= 3)) {
      return Future.value();
    }
    final running = _poolLoading;
    if (running != null && _poolSeedId == seed.id) return running;
    _poolSeedId = seed.id;
    final f = _loadPool(seed, _epoch);
    _poolLoading = f;
    return f;
  }

  Future<List<_Candidate>> _similarFor(String artist, String title) async {
    if (artist.trim().isEmpty || title.trim().isEmpty) return const [];
    try {
      final sims = await ApiService.getSimilarTracks(artist, title);
      return sims.map((s) => _Candidate(s.artist, s.name)).toList();
    } catch (e) {
      debugPrint('auto-queue: similar tracks failed for "$artist - $title": $e');
      return const [];
    }
  }

  Future<void> _loadPool(Track seed, int epoch) async {
    final artist = seed.artist.trim();
    final title = cleanTitle(seed.title);
    final seedKey = _Candidate(artist, title).key;
    const enough = 5;

    if (_wanted != null && _artistOk) {
      final result = await _loadArtistPool(seed, epoch);
      if (epoch != _epoch || _poolSeedId != seed.id) return;
      if (result == _ArtistPool.ready) return;
      if (result == _ArtistPool.failed) {
        _poolSeedId = null;
        _poolLoading = null;
        return;
      }
      _artistOk = false;
    } else if (_wanted == null && _settings.mode.value == AutoQueueMode.sameArtist) {
      _artistOk = false;
      _settings.say('The artist of this song is not known, so similar songs play');
    }

    final found = <_Candidate>[];
    if (seed.isPlayable && _ytmTried.add(seed.id)) {
      try {
        final similar = await ApiService.getSimilarYtm(
          seed.id,
          query: '$artist $title'.trim(),
          artist: artist,
        );
        for (final t in similar) {
          final secs = _seconds(t.duration);
          if (secs < 60 || secs > 900 || _junk.hasMatch(t.title)) continue;
          if (t.artist.trim().isEmpty) continue;
          if (_norm(cleanTitle(t.title)) == _norm(title)) continue;
          found.add(_Candidate(t.artist, t.title, t));
        }
        debugPrint('auto-queue: YouTube Music gave ${found.length} songs');
      } catch (e) {
        debugPrint('auto-queue: YouTube Music failed, using Last.fm: $e');
      }
    }

    if (found.length < enough && seed.isPlayable) {
      try {
        var n = 0;
        for (final t in await ApiService.getRelated(seed.id)) {
          final secs = _seconds(t.duration);
          if (secs < 60 || secs > 900 || _junk.hasMatch(t.title)) continue;
          if (t.artist.trim().isEmpty) continue;
          if (_norm(cleanTitle(t.title)) == _norm(title)) continue;
          found.add(_Candidate(t.artist, t.title, t));
          n++;
        }
        debugPrint('auto-queue: YouTube mix gave $n songs');
      } catch (e) {
        debugPrint('auto-queue: YouTube mix failed: $e');
      }
    }

    if (found.length < enough) found.addAll(await _similarFor(artist, title));

    if (found.length < enough && title.isNotEmpty) {
      try {
        final matches = await ApiService.searchLastFmTracks(title, limit: 3);
        for (final m in matches) {
          if (m.artist.toLowerCase() != artist.toLowerCase()) continue;
          if (_Candidate(m.artist, m.name).key == seedKey) continue;
          final sims = await _similarFor(m.artist, m.name);
          if (sims.isNotEmpty) {
            debugPrint('auto-queue: using Last.fm match "${m.artist} - ${m.name}"');
            found.addAll(sims);
            break;
          }
        }
      } catch (e) {
        debugPrint('auto-queue: title lookup failed: $e');
      }
    }

    if (found.length < enough && artist.isNotEmpty) {
      try {
        final top = await ApiService.getArtistTopTracks(artist);
        found.addAll(top.map(
            (t) => _Candidate(t.artist.isEmpty ? artist : t.artist, t.title)));
      } catch (e) {
        debugPrint('auto-queue: artist top tracks failed: $e');
      }
    }
    if (found.length < enough && artist.isNotEmpty) {
      try {
        final names = await ApiService.getSimilarArtistNames(artist);
        for (final name in names.take(3)) {
          final top = await ApiService.getArtistTopTracks(name);
          found.addAll(top.take(5).map(
              (t) => _Candidate(t.artist.isEmpty ? name : t.artist, t.title)));
        }
      } catch (e) {
        debugPrint('auto-queue: similar artists failed: $e');
      }
    }

    if (epoch != _epoch || _poolSeedId != seed.id) return;
    final seen = <String>{};
    _pool = [...found, ..._pool]
        .where((c) =>
            !_usedKeys.contains(c.key) &&
            !_playedTitles.contains(_titleKey(c.name)) &&
            seen.add(c.key))
        .toList();
    _loadedFor = seed.id;
    debugPrint('auto-queue: ${_pool.length} candidates for "$artist - $title"');
  }

  Future<_ArtistPool> _loadArtistPool(Track seed, int epoch) async {
    var focus = _settings.focus.value;
    if (focus == null) return _ArtistPool.none;

    if (focus.needsCheck) {
      final noArtistText = focus.credit.isEmpty;
      final asked = noArtistText ? focus.name : (focus.credit.act ?? focus.name);
      var songs = <_Candidate>[];
      try {
        songs = await _fetchArtist(asked);
      } catch (e) {
        debugPrint('auto-queue: could not check "$asked": $e');
        return _ArtistPool.failed;
      }
      if (epoch != _epoch) return _ArtistPool.failed;
      if (songs.isNotEmpty) {
        final spelled = noArtistText ? _spelling(songs, asked) : asked;
        _settings.confirm(focus, spelled);
        _keep(spelled, songs);
      } else {
        _settings.deny(focus);
      }
      focus = _settings.focus.value;
      if (focus == null) {
        _wanted = null;
        _settings.say('The artist of this song is not known, so similar songs play');
        return _ArtistPool.none;
      }
      _wanted = focus.name;
    }

    final name = focus.name;
    final source = await _artistSongs(name, epoch);
    if (epoch != _epoch || _poolSeedId != seed.id) return _ArtistPool.failed;
    if (source == null) return _ArtistPool.failed;
    if (source.isEmpty) {
      _settings.say('No songs by $name found, so similar songs play');
      return _ArtistPool.none;
    }
    _artistIds.addAll(source.map((c) => c.ready?.id).whereType<String>());

    final seedTitle = _titleKey(seed.title);
    List<_Candidate> fresh() {
      final seen = <String>{};
      return source.where((c) {
        final id = c.ready?.id;
        final title = _titleKey(c.name);
        return id != seed.id &&
            title != seedTitle &&
            !_usedKeys.contains(c.key) &&
            !(id != null && _usedIds.contains(id)) &&
            !_playedTitles.contains(title) &&
            seen.add(c.key);
      }).toList();
    }

    var cands = fresh();
    if (cands.isEmpty && source.length >= 3) {
      _recycle(max(1, min(4, source.length ~/ 2)));
      cands = fresh();
      debugPrint('auto-queue: every song by "$name" played, starting over (${cands.length} candidates)');
    }
    if (cands.isEmpty) {
      _settings.say('No more songs by $name to play, so similar songs play');
      return _ArtistPool.none;
    }
    _pool = cands;
    _loadedFor = seed.id;
    _settings.say(null);
    debugPrint('auto-queue: ${_pool.length} songs by "$name" for "${seed.artist} - ${seed.title}"');
    return _ArtistPool.ready;
  }

  Future<List<_Candidate>?> _artistSongs(String name, int epoch) async {
    if (_sourceFor == ArtistCredit.norm(name) &&
        DateTime.now().difference(_sourceAt) < _sourceTtl) {
      return _source;
    }
    final songs = <_Candidate>[];
    var answered = false;
    try {
      songs.addAll(await _fetchArtist(name));
      answered = true;
    } catch (e) {
      debugPrint('auto-queue: YouTube Music songs by "$name" failed: $e');
    }
    if (epoch != _epoch) return null;
    if (songs.length < 10) {
      try {
        for (final t in await ApiService.getArtistTopTracks(name)) {
          if (t.title.trim().isNotEmpty) songs.add(_Candidate(name, t.title));
        }
      } catch (e) {
        debugPrint('auto-queue: top songs by "$name" failed: $e');
      }
      if (epoch != _epoch) return null;
    }
    if (songs.length < 5) {
      try {
        for (final t in await ApiService.searchTracks(name, limit: 25)) {
          if (_fits(t) && ArtistCredit.of(t).has(name)) {
            songs.add(_Candidate(name, t.title, _named(t, name)));
          }
        }
      } catch (e) {
        debugPrint('auto-queue: search for "$name" failed: $e');
      }
      if (epoch != _epoch) return null;
    }
    if (songs.isEmpty && !answered) return null;
    if (songs.isNotEmpty) _keep(name, songs);
    return songs;
  }

  Future<List<_Candidate>> _fetchArtist(String name) async {
    final out = <_Candidate>[];
    for (final t in await ApiService.getArtistSongsYtm(name)) {
      if (!_fits(t)) continue;
      out.add(_Candidate(t.artist.trim().isEmpty ? name : t.artist, t.title, _named(t, name)));
    }
    return out;
  }

  void _keep(String name, List<_Candidate> songs) {
    _source = songs;
    _sourceFor = ArtistCredit.norm(name);
    _sourceAt = DateTime.now();
  }

  static String _spelling(List<_Candidate> songs, String typed) {
    final count = <String, int>{};
    for (final c in songs) {
      final n = ArtistCredit.parse(c.artist).named(typed);
      if (n != null) count[n] = (count[n] ?? 0) + 1;
    }
    var best = typed;
    var most = 0;
    for (final e in count.entries) {
      if (e.value > most) {
        best = e.key;
        most = e.value;
      }
    }
    return best;
  }

  static bool _fits(Track t) {
    final secs = _seconds(t.duration);
    return secs >= 60 && secs <= 900 && !_junk.hasMatch(t.title);
  }

  static Track _named(Track t, String artist) => t.artist.trim().isNotEmpty
      ? t
      : Track(
          id: t.id,
          title: t.title,
          artist: artist,
          album: t.album,
          duration: t.duration,
          imageUrl: t.imageUrl,
          previewUrl: t.previewUrl,
          isExplicit: t.isExplicit,
        );

  void _recycle(int keep) {
    final kept = _recent.length <= keep
        ? List<Track>.of(_recent)
        : _recent.sublist(_recent.length - keep);
    _usedIds
      ..clear()
      ..addAll(kept.map((t) => t.id));
    _usedKeys
      ..clear()
      ..addAll(kept.map((t) => _Candidate(t.artist, cleanTitle(t.title)).key));
    _playedIds
      ..clear()
      ..addAll(kept.map((t) => t.id));
    _playedTitles
      ..clear()
      ..addAll(kept.map((t) => _titleKey(t.title)));
  }

  bool _byFocus(Track t) {
    final want = _wanted;
    if (want == null || !_artistOk) return true;
    final credit = ArtistCredit.of(t);
    return credit.isEmpty || credit.has(want);
  }

  Future<Track?> _choose() async {
    final epoch = _epoch;
    var tries = 0;
    while (_pool.isNotEmpty && tries < 5) {
      final c = _pool.removeAt(_rng.nextInt(min(_pool.length, 5)));
      if (_usedKeys.contains(c.key) || _playedTitles.contains(_titleKey(c.name))) continue;
      tries++;
      Track? t;
      try {
        t = c.ready ?? await _toPlayable(c);
      } catch (e) {
        if ((_retries[c.key] = (_retries[c.key] ?? 0) + 1) <= 1) _pool.add(c);
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      if (epoch != _epoch) return null;
      if (t == null || _usedIds.contains(t.id)) continue;
      if (t.artist.trim().isEmpty) {
        debugPrint('auto-queue: skipped "${c.name}" (${t.id}): no artist');
        continue;
      }
      _usedKeys.add(c.key);
      _usedIds.add(t.id);
      if (_wanted != null && _artistOk) _artistIds.add(t.id);
      debugPrint('auto-queue: picked "${c.artist} - ${c.name}" (${t.id}), ${_pool.length} left');
      return t;
    }
    return null;
  }

  Future<Track?> _toPlayable(_Candidate c) async {
      final results = await ApiService.searchTracks('${c.artist} ${c.name}', limit: 6);
      final want = _norm(cleanTitle(c.name));
      final hit = results.where((t) =>
          _seconds(t.duration) >= 60 &&
          !_junk.hasMatch(t.title) &&
          _byFocus(t) &&
          _norm(t.title).contains(want));
      if (hit.isEmpty) return null;
      final t = hit.first;
      return Track(
        id: t.id,
        title: c.name,
        artist: c.artist,
        album: t.album,
        duration: t.duration,
        imageUrl: t.imageUrl,
        previewUrl: t.previewUrl,
      );
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static int _seconds(String d) {
    final p = d.split(':').map(int.tryParse).toList();
    if (p.any((x) => x == null)) return 0;
    if (p.length == 2) return p[0]! * 60 + p[1]!;
    if (p.length == 3) return p[0]! * 3600 + p[1]! * 60 + p[2]!;
    return 0;
  }
}
