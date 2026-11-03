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
  final Track? ready; // already a playable YouTube track, no lookup needed
  const _Candidate(this.artist, this.name, [this.ready]);
  String get key => '${artist.toLowerCase()}|${name.toLowerCase()}';
}

/// How loading the songs of the followed artist went (same-artist mode).
enum _ArtistPool {
  ready, // there are songs to pick from
  none, // the artist has no (more) songs we can play: similar songs take over
  failed, // the server could not be asked: nothing is known, try again later
}

/// Decides what plays next: Last.fm similarity (via the backend), turned into
/// a playable YouTube track with the backend /search. In "same artist" mode (see
/// [AutoQueueSettings]) it is the followed artist's own songs instead.
class AutoQueueService {
  final Random _rng = Random();
  final AutoQueueSettings _settings = AutoQueueSettings.instance;
  final Set<String> _usedIds = {};
  final Set<String> _usedKeys = {};
  // Songs that really played this session (the two sets above also hold songs that were
  // only picked). A pick made earlier can turn out to be a song that played in between,
  // e.g. one the user queued by hand.
  final Set<String> _playedIds = {};
  final Set<String> _playedTitles = {};
  List<_Candidate> _pool = [];
  String? _poolSeedId;
  String? _loadedFor;
  Future<void>? _poolLoading;
  Future<Track?>? _nextFuture;
  int _epoch = 0;
  final Set<String> _ytmTried = {}; // one YouTube Music request per song
  final Map<String, int> _retries = {};

  // Same-artist mode
  String? _wanted; // the artist the pool is made for (null: similar songs)
  bool _artistOk = true; // false: nothing playable by that artist, similar songs play instead
  final Set<String> _artistIds = {}; // songs that came from the followed artist's own list
  final List<Track> _recent = []; // the last songs that played; they stay out when the list starts over
  List<_Candidate> _source = const []; // the followed artist's songs, kept for refills
  String _sourceFor = '';
  DateTime _sourceAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _sourceTtl = Duration(minutes: 30);

  static final RegExp _junk = RegExp(
    r'\b(cover|karaoke|reaction|tutorial|nightcore|slowed|sped up|8d)\b',
    caseSensitive: false,
  );

  /// Strips "(Official Video)", "feat. X" and similar so Last.fm can match.
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

  /// The user picked a song: start a fresh listening session. [searchedFor] is what the user
  /// searched for to find it (an artist name, say), if they did: "same artist" follows that
  /// artist when the song is credited to them.
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
    // same-artist mode: the artist is decided again for this song, once the queue needs it
    _settings.begin(searchedFor);
    _artistOk = true;
    _artistIds.clear();
    _recent.clear();
    _remember(seed);
  }

  /// The setting changed (or an artist was chosen): pick again from scratch.
  /// What already played stays played.
  void restart() {
    _reset();
    _artistOk = true; // ask again for the artist's songs
  }

  static String _titleKey(String title) => _norm(cleanTitle(title));

  /// Same video, or the same song title, as something that already played this session.
  bool _alreadyPlayed(Track t) =>
      _playedIds.contains(t.id) || _playedTitles.contains(_titleKey(t.title));

  /// Playback moved on to [t] by itself (or via next).
  void advanced(Track t) {
    // No reset: keep drawing from the pool built for the song the user picked,
    // so the radio doesn't drift further away with every hop.
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

  /// Same-artist mode: the artist the next songs must come from; null in the default mode, and
  /// when the song has no known artist. Decided here, for the song that is playing, because
  /// this is when the auto queue is in charge (a playlist or the user's queue come first).
  String? focusFor(Track seed) {
    if (_settings.mode.value != AutoQueueMode.sameArtist) return null;
    // No songs to follow for this artist: similar songs play until the user starts another
    // song or changes the setting (the queue does not hop to the artist of each similar song).
    if (!_artistOk) return _wanted;
    // A song this queue took from the artist's own list stays with that artist, however
    // YouTube writes its artist text (the artist may be listed second on it).
    if (!(_artistIds.contains(seed.id) && _settings.focus.value != null)) {
      _settings.follow(seed);
    }
    return _settings.focus.value?.name;
  }

  /// A pool made for another artist (or for similar songs) is of no use after a change.
  void _syncPool(Track seed) {
    final want = focusFor(seed);
    if (want == _wanted) return;
    _reset();
    _wanted = want;
    _artistOk = true;
  }

  /// Picks the next song in the background so nextFor() answers instantly.
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
    // an early pick can have found nothing because the pool was still empty then
    if (t == null && epoch == _epoch && _pool.isNotEmpty) t = await _choose();
    // the pick may have been made before a song played that is the same one (queued by hand)
    for (var i = 0; t != null && _alreadyPlayed(t) && i < 3; i++) {
      debugPrint('auto-queue: dropped "${t.title}" (${t.id}), it already played');
      if (epoch != _epoch) return null;
      t = await _choose();
    }
    if (t != null && _alreadyPlayed(t)) return null;
    return epoch == _epoch ? t : null;
  }

  Future<void> _ensurePool(Track seed) {
    // ponytail: refills from the newest song once fewer than 3 candidates are left
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

  /// Builds the list of songs that could play next. Unreleased songs (common on
  /// YouTube) are unknown to Last.fm, so this falls back step by step:
  /// 1. similar songs for this exact song
  /// 2. the song title looked up on Last.fm, then similar songs for that match
  /// 3. similar songs for what was played before this one
  /// 4. the artist's top songs, then similar artists' top songs
  Future<void> _loadPool(Track seed, int epoch) async {
    final artist = seed.artist.trim();
    final title = cleanTitle(seed.title);
    final seedKey = _Candidate(artist, title).key;
    const enough = 5;

    // Same artist only: the artist's own songs. Without any, similar songs play instead,
    // and the player says so.
    if (_wanted != null && _artistOk) {
      final result = await _loadArtistPool(seed, epoch);
      if (epoch != _epoch || _poolSeedId != seed.id) return;
      if (result == _ArtistPool.ready) return;
      if (result == _ArtistPool.failed) {
        // the server could not be asked: nothing is known yet, so ask again next time
        _poolSeedId = null;
        _poolLoading = null;
        return;
      }
      _artistOk = false; // similar songs take over (the note says why)
    } else if (_wanted == null && _settings.mode.value == AutoQueueMode.sameArtist) {
      _artistOk = false; // similar songs, for as long as this lasts (see focusFor)
      _settings.say('The artist of this song is not known, so similar songs play');
    }

    // 0) YouTube Music: its radio, or a song search for the title when there is no
    //    radio (unreleased songs). Results are playable already; Last.fm is the fallback.
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
          if (t.artist.trim().isEmpty) continue; // an artist-less song would seed the next pick with nothing
          if (_norm(cleanTitle(t.title)) == _norm(title)) continue; // same song again
          found.add(_Candidate(t.artist, t.title, t));
        }
        debugPrint('auto-queue: YouTube Music gave ${found.length} songs');
      } catch (e) {
        debugPrint('auto-queue: YouTube Music failed, using Last.fm: $e');
      }
    }

    // 0b) YouTube's own mix for this video. Works for unreleased uploads too; the
    //     backend answers 503 when it is busy, and Last.fm takes over.
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

    // 1) this exact song
    if (found.length < enough) found.addAll(await _similarFor(artist, title));

    // 2) look the title up on Last.fm and use the best different match
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

    // 4) artist level
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
    // fresh candidates first, then the unused rest of the earlier pool (the reserve)
    _pool = [...found, ..._pool]
        .where((c) =>
            !_usedKeys.contains(c.key) &&
            !_playedTitles.contains(_titleKey(c.name)) &&
            seen.add(c.key))
        .toList();
    _loadedFor = seed.id;
    debugPrint('auto-queue: ${_pool.length} candidates for "$artist - $title"');
  }

  /// Same-artist mode: makes the pool from the followed artist's own songs. Never throws.
  Future<_ArtistPool> _loadArtistPool(Track seed, int epoch) async {
    var focus = _settings.focus.value;
    if (focus == null) return _ArtistPool.none;

    // Not sure yet that the name is one artist: YouTube Music is asked first (see
    // ArtistFocus.needsCheck). "Drake & Future" is two artists, so the first one is followed,
    // unless YouTube Music knows the whole credit as one act ("Coheed and Cambria"). A song
    // without an artist text follows what the user searched for, if that is an artist.
    if (focus.needsCheck) {
      final noArtistText = focus.credit.isEmpty;
      final asked = noArtistText ? focus.name : (focus.credit.act ?? focus.name);
      var songs = <_Candidate>[];
      try {
        songs = await _fetchArtist(asked);
      } catch (e) {
        debugPrint('auto-queue: could not check "$asked": $e');
        return _ArtistPool.failed; // nothing is known: ask again next time
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
        // the search text is no artist, and the song names none: similar songs play
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
      // every song by the artist has played: start over, with the last few kept out
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

  /// The followed artist's songs: from YouTube Music (playable already), then Last.fm's top
  /// songs (found on YouTube one by one when they are picked), then a plain search. Null when
  /// the server could not be asked; an empty list means there are none.
  Future<List<_Candidate>?> _artistSongs(String name, int epoch) async {
    if (_sourceFor == ArtistCredit.norm(name) &&
        DateTime.now().difference(_sourceAt) < _sourceTtl) {
      return _source;
    }
    final songs = <_Candidate>[];
    var answered = false; // YouTube Music replied (an empty reply: it has no such artist)
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
    if (songs.isEmpty && !answered) return null; // nothing known: not "no such artist"
    if (songs.isNotEmpty) _keep(name, songs);
    return songs;
  }

  /// The artist's songs on YouTube Music, matched by exact artist name (the server answers an
  /// empty list for an unknown artist). Throws when the server cannot be asked.
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

  /// How YouTube Music writes the artist that [typed] was searched as: the commonest spelling of
  /// that name among [songs] ("drake" gives "Drake").
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

  /// A song of a sensible length that is not a cover, karaoke version and so on.
  static bool _fits(Track t) {
    final secs = _seconds(t.duration);
    return secs >= 60 && secs <= 900 && !_junk.hasMatch(t.title);
  }

  /// [t] with [artist] filled in when it came without one (a queued song needs an artist).
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

  /// Every song of the artist has played: forget what played, except the last [keep] songs, so
  /// that one of them does not come straight back.
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

  /// Same-artist mode: a song found by searching must not name somebody else as its artist.
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
      // a little variety: pick among the 5 best matches
      final c = _pool.removeAt(_rng.nextInt(min(_pool.length, 5)));
      if (_usedKeys.contains(c.key) || _playedTitles.contains(_titleKey(c.name))) continue;
      tries++;
      Track? t;
      try {
        t = c.ready ?? await _toPlayable(c);
      } catch (e) {
        // network hiccup, not a bad song: keep it for one more try
        if ((_retries[c.key] = (_retries[c.key] ?? 0) + 1) <= 1) _pool.add(c);
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      if (epoch != _epoch) return null;
      if (t == null || _usedIds.contains(t.id)) continue;
      if (t.artist.trim().isEmpty) {
        debugPrint('auto-queue: skipped "${c.name}" (${t.id}): no artist');
        continue; // never queue a song without an artist: the next pick would drift
      }
      _usedKeys.add(c.key);
      _usedIds.add(t.id);
      if (_wanted != null && _artistOk) _artistIds.add(t.id); // stays with the artist, see focusFor
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
          _norm(t.title).contains(want)); // no loose fallback: a wrong song is worse than skipping
      if (hit.isEmpty) return null;
      final t = hit.first;
      // Keep Last.fm's artist/title: the next hop seeds from them, and YouTube
      // titles ("Song (Official Video)") don't parse into a reliable artist.
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
