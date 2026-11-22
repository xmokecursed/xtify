import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'secure_prefs.dart';
import '../models/track_model.dart';
import 'artist_mix_service.dart';
import 'track_lookup.dart';
import 'youtube_catalog.dart';

class FeedService {
  FeedService._();
  static final FeedService instance = FeedService._();

  static const Duration _ttl = Duration(hours: 6);
  static const String _trendKey = 'feed_trending';

  final ValueNotifier<List<Track>> trending = ValueNotifier<List<Track>>(const []);
  final ValueNotifier<bool> loadingTrending = ValueNotifier<bool>(false);

  int _trendAt = 0;

  bool _fresh(int at) =>
      DateTime.now().millisecondsSinceEpoch - at < _ttl.inMilliseconds;

  Future<void> init() async {
    final prefs = await SecurePrefs.getInstance();
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
    final prefs = await SecurePrefs.getInstance();
    await prefs.setString(
      key,
      json.encode({
        'at': DateTime.now().millisecondsSinceEpoch,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      }),
    );
  }

  Future<void> refreshAll({bool force = false}) async {
    await refreshTrending(force: force);
    await ArtistMixService.instance.refresh(force: force);
  }

  Future<void> refreshTrending({bool force = false}) async {
    if (loadingTrending.value) return;
    if (!force && _fresh(_trendAt) && trending.value.isNotEmpty) return;
    loadingTrending.value = true;
    try {
      final chart = await YouTubeCatalog.trending(limit: 16);
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
}
