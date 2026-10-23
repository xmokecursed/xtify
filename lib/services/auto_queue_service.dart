import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/track_model.dart';
import 'api_service.dart';
import 'history_service.dart';

class _Candidate {
  final String artist;
  final String name;
  final Track? ready; // already a playable YouTube track, no lookup needed
  const _Candidate(this.artist, this.name, [this.ready]);
  String get key => '${artist.toLowerCase()}|${name.toLowerCase()}';
}

/// Decides what plays next: Last.fm similarity (via the backend), turned into
/// a playable YouTube track with the backend /search.
class AutoQueueService {
  final Random _rng = Random();
  final Set<String> _usedIds = {};
  final Set<String> _usedKeys = {};
  List<_Candidate> _pool = [];
  String? _poolSeedId;
  String? _loadedFor;
  Future<void>? _poolLoading;
  Future<Track?>? _nextFuture;
  int _epoch = 0;
  final Set<String> _ytmTried = {}; // one YouTube Music request per song
  final Map<String, int> _retries = {};

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

  /// The user picked a song: start a fresh listening session.
  void startSession(Track seed) {
    _reset();
    _usedIds
      ..clear()
      ..add(seed.id);
    _usedKeys
      ..clear()
      ..add(_Candidate(seed.artist, cleanTitle(seed.title)).key);
  }

  /// Playback moved on to [t] by itself (or via next).
  void advanced(Track t) {
    // No reset: keep drawing from the pool built for the song the user picked,
    // so the radio doesn't drift further away with every hop.
    _usedIds.add(t.id);
    _usedKeys.add(_Candidate(t.artist, cleanTitle(t.title)).key);
  }

  /// Picks the next song in the background so nextFor() answers instantly.
  Future<void> warm(Track seed) async {
    final epoch = _epoch;
    await _ensurePool(seed);
    if (epoch != _epoch) return;
    _nextFuture ??= _choose();
  }

  Future<Track?> nextFor(Track seed) async {
    final epoch = _epoch;
    await _ensurePool(seed);
    if (epoch != _epoch) return null;
    final f = _nextFuture ?? _choose();
    _nextFuture = null;
    final t = await f;
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

    // 3) previously played songs, most recent first
    if (found.length < enough) {
      final previous = HistoryService.instance.tracks.value
          .where((t) => t.id != seed.id)
          .take(3);
      for (final prev in previous) {
        found.addAll(await _similarFor(prev.artist, cleanTitle(prev.title)));
        if (found.length >= enough) {
          debugPrint('auto-queue: seeded from earlier song "${prev.title}"');
          break;
        }
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
        .where((c) => !_usedKeys.contains(c.key) && seen.add(c.key))
        .toList();
    _loadedFor = seed.id;
    debugPrint('auto-queue: ${_pool.length} candidates for "$artist - $title"');
  }

  Future<Track?> _choose() async {
    final epoch = _epoch;
    var tries = 0;
    while (_pool.isNotEmpty && tries < 5) {
      // a little variety: pick among the 5 best matches
      final c = _pool.removeAt(_rng.nextInt(min(_pool.length, 5)));
      if (_usedKeys.contains(c.key)) continue;
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
