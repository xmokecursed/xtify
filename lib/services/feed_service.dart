import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track_model.dart';
import 'api_service.dart';
import 'artist_mix_service.dart';
import 'auto_queue_service.dart';
import 'history_service.dart';
import 'track_lookup.dart';

/// Home-screen feeds: "Made for you" (from play history) and trending songs.
/// Both are cached on the phone so they show instantly on the next launch.
class FeedService {
  FeedService._();
  static final FeedService instance = FeedService._();

  static const Duration _ttl = Duration(hours: 6);
  static const String _madeKey = 'feed_made_for_you';
  static const String _trendKey = 'feed_trending';
  static const String _madeSigKey = 'feed_made_sig';

  final ValueNotifier<List<Track>> madeForYou = ValueNotifier<List<Track>>(const []);
  final ValueNotifier<List<Track>> trending = ValueNotifier<List<Track>>(const []);
  final ValueNotifier<bool> loadingMade = ValueNotifier<bool>(false);
  final ValueNotifier<bool> loadingTrending = ValueNotifier<bool>(false);

  int _madeAt = 0;
  int _trendAt = 0;
  String _madeSig = '';

  bool _fresh(int at) =>
      DateTime.now().millisecondsSinceEpoch - at < _ttl.inMilliseconds;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _madeSig = prefs.getString(_madeSigKey) ?? '';
    final made = _load(prefs.getString(_madeKey));
    madeForYou.value = made.$2;
    _madeAt = made.$1;
    final trend = _load(prefs.getString(_trendKey));
    trending.value = trend.$2;
    _trendAt = trend.$1;
  }

  (int, List<Track>) _load(String? raw) {
    if (raw == null) return (0, const <Track>[]);
    try {
      final m = json.decode(raw) as Map<String, dynamic>;
      final list = (m['tracks'] as List<dynamic>)
          .map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList();
      return ((m['at'] as num).toInt(), list);
    } catch (_) {
      return (0, const <Track>[]);
    }
  }

  Future<void> _save(String key, List<Track> tracks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      json.encode({
        'at': DateTime.now().millisecondsSinceEpoch,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      }),
    );
  }

  /// Refreshes both feeds one after the other (each song needs a backend search,
  /// so doing both at once would hammer the server).
  Future<void> refreshAll({bool force = false}) async {
    await refreshTrending(force: force);
    await ArtistMixService.instance.refresh(force: force);
  }

  /// Global Last.fm chart, turned into playable songs.
  Future<void> refreshTrending({bool force = false}) async {
    if (loadingTrending.value) return;
    if (!force && _fresh(_trendAt) && trending.value.isNotEmpty) return;
    loadingTrending.value = true;
    try {
      final chart = await ApiService.getTrending(limit: 16);
      final queries = chart.map((s) => TrackQuery(s.artist, s.name)).toList();
      final empty = trending.value.isEmpty;
      final found = await TrackLookup.resolveAll(
        queries,
        max: 10,
        onProgress: empty ? (list) => trending.value = list : null,
      );
      if (found.isNotEmpty) {
        trending.value = found;
        _trendAt = DateTime.now().millisecondsSinceEpoch;
        await _save(_trendKey, found);
      }
    } catch (e) {
      debugPrint('trending refresh failed: $e');
    } finally {
      loadingTrending.value = false;
    }
  }

  /// Songs similar to what the user played recently.
  Future<void> refreshMadeForYou({bool force = false}) async {
    final history = HistoryService.instance.tracks.value;
    if (history.isEmpty) {
      madeForYou.value = const [];
      return;
    }
    if (loadingMade.value) return;

    final topArtists =
        HistoryService.instance.artists.value.take(3).map((a) => a.name).toList();
    final sig = topArtists.join('|').toLowerCase();
    if (!force && _fresh(_madeAt) && sig == _madeSig && madeForYou.value.isNotEmpty) {
      return;
    }

    loadingMade.value = true;
    try {
      final playedKeys = <String>{
        for (final t in history)
          '${t.artist.toLowerCase()}|${AutoQueueService.cleanTitle(t.title).toLowerCase()}',
      };

      final sources = <List<TrackQuery>>[];
      for (final seed in history.take(3)) {
        if (seed.artist.isEmpty) continue;
        try {
          final sims = await ApiService.getSimilarTracks(
            seed.artist,
            AutoQueueService.cleanTitle(seed.title),
            limit: 15,
          );
          sources.add(sims.map((s) => TrackQuery(s.artist, s.name)).toList());
        } catch (e) {
          debugPrint('made-for-you: similar tracks failed: $e');
        }
      }
      for (final name in topArtists) {
        try {
          final top = await ApiService.getArtistTopTracks(name);
          sources.add(top.take(6).map((t) => TrackQuery(name, t.title)).toList());
        } catch (e) {
          debugPrint('made-for-you: top tracks failed: $e');
        }
      }

      // Mix the sources so one artist doesn't dominate, skip songs already played.
      final queries = <TrackQuery>[];
      final seen = <String>{...playedKeys};
      for (var i = 0; queries.length < 20; i++) {
        var any = false;
        for (final s in sources) {
          if (i < s.length) {
            any = true;
            if (seen.add(s[i].key)) queries.add(s[i]);
          }
        }
        if (!any) break;
      }

      final empty = madeForYou.value.isEmpty;
      final found = await TrackLookup.resolveAll(
        queries,
        max: 8,
        excludeIds: history.map((t) => t.id).toSet(),
        onProgress: empty ? (list) => madeForYou.value = list : null,
      );
      if (found.isNotEmpty) {
        found.shuffle(Random());
        madeForYou.value = found;
        _madeAt = DateTime.now().millisecondsSinceEpoch;
        _madeSig = sig;
        await _save(_madeKey, found);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_madeSigKey, sig);
      }
    } catch (e) {
      debugPrint('made-for-you refresh failed: $e');
    } finally {
      loadingMade.value = false;
    }
  }
}
