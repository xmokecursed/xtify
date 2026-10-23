import 'package:flutter/foundation.dart';
import '../models/track_model.dart';
import 'api_service.dart';

class TrackQuery {
  final String artist;
  final String name;
  const TrackQuery(this.artist, this.name);
  String get key => '${artist.toLowerCase()}|${name.toLowerCase()}';
}

/// Turns "artist + song name" (Last.fm data, no video id) into a playable
/// YouTube track through the backend search.
class TrackLookup {
  static final RegExp _junk = RegExp(
    r'\b(cover|karaoke|reaction|tutorial|nightcore|slowed|sped up|8d)\b',
    caseSensitive: false,
  );

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static int _seconds(String d) {
    final p = d.split(':').map(int.tryParse).toList();
    if (p.any((x) => x == null)) return 0;
    if (p.length == 2) return p[0]! * 60 + p[1]!;
    if (p.length == 3) return p[0]! * 3600 + p[1]! * 60 + p[2]!;
    return 0;
  }

  static Future<Track?> find(String artist, String name) async {
    try {
      final results = await ApiService.searchTracks('$artist $name', limit: 6);
      final want = _norm(name);
      final ok = results
          .where((t) => _seconds(t.duration) >= 60 && !_junk.hasMatch(t.title))
          .toList();
      if (ok.isEmpty) return null;
      final exact = ok.where((t) => _norm(t.title).contains(want)).toList();
      return (exact.isNotEmpty ? exact : ok).first;
    } catch (e) {
      debugPrint('lookup failed for "$artist $name": $e');
      return null;
    }
  }

  /// Resolves [queries] a few at a time and stops after [max] hits.
  /// [onProgress] receives the list found so far.
  static Future<List<Track>> resolveAll(
    List<TrackQuery> queries, {
    int max = 10,
    Set<String> excludeIds = const {},
    void Function(List<Track>)? onProgress,
    int concurrency = 2,
  }) async {
    final results = List<Track?>.filled(queries.length, null);
    var next = 0;

    List<Track> snapshot() {
      final list = results.whereType<Track>().toList();
      return list.length > max ? list.sublist(0, max) : list;
    }

    Future<void> worker() async {
      while (true) {
        if (results.whereType<Track>().length >= max) return;
        final i = next++;
        if (i >= queries.length) return;
        final t = await find(queries[i].artist, queries[i].name);
        if (t == null || excludeIds.contains(t.id)) continue;
        if (results.any((r) => r?.id == t.id)) continue;
        results[i] = t;
        onProgress?.call(snapshot());
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    return snapshot();
  }
}
