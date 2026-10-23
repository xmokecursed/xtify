import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track_model.dart';

/// An artist the user has played, with how often and when.
class ArtistEntry {
  final String name;
  final int plays;
  final int lastPlayedMs;
  final String imageUrl;

  const ArtistEntry({
    required this.name,
    required this.plays,
    required this.lastPlayedMs,
    required this.imageUrl,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'plays': plays,
        'last': lastPlayedMs,
        'img': imageUrl,
      };

  factory ArtistEntry.fromJson(Map<String, dynamic> j) => ArtistEntry(
        name: (j['name'] ?? '').toString(),
        plays: (j['plays'] as num?)?.toInt() ?? 0,
        lastPlayedMs: (j['last'] as num?)?.toInt() ?? 0,
        imageUrl: (j['img'] ?? '').toString(),
      );
}

class HistoryService {
  HistoryService._();
  static final HistoryService instance = HistoryService._();

  static const String _key = 'play_history';
  static const String _artistKey = 'artist_stats';
  static const int _max = 30;
  static const int _maxArtists = 100;

  final ValueNotifier<List<Track>> tracks = ValueNotifier<List<Track>>(const []);

  /// Played artists, most played first.
  final ValueNotifier<List<ArtistEntry>> artists =
      ValueNotifier<List<ArtistEntry>>(const []);

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <Track>[];
    for (final s in prefs.getStringList(_key) ?? const <String>[]) {
      try {
        out.add(Track.fromJson(json.decode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    tracks.value = out;

    final stats = <ArtistEntry>[];
    for (final s in prefs.getStringList(_artistKey) ?? const <String>[]) {
      try {
        stats.add(ArtistEntry.fromJson(json.decode(s) as Map<String, dynamic>));
      } catch (_) {}
    }
    artists.value = _sorted(stats);
  }

  static List<ArtistEntry> _sorted(List<ArtistEntry> list) {
    final copy = [...list];
    copy.sort((a, b) {
      final byPlays = b.plays.compareTo(a.plays);
      return byPlays != 0 ? byPlays : b.lastPlayedMs.compareTo(a.lastPlayedMs);
    });
    return copy;
  }

  Future<void> add(Track t) async {
    final list = [t, ...tracks.value.where((x) => x.id != t.id)];
    if (list.length > _max) list.removeRange(_max, list.length);
    tracks.value = list;

    final name = t.artist.trim();
    if (name.isNotEmpty) _countArtist(name, t.imageUrl);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      list.map((x) => json.encode(x.toJson())).toList(),
    );
    await prefs.setStringList(
      _artistKey,
      artists.value.map((a) => json.encode(a.toJson())).toList(),
    );
  }

  void _countArtist(String name, String imageUrl) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final list = [...artists.value];
    final i = list.indexWhere((a) => a.name.toLowerCase() == name.toLowerCase());
    if (i >= 0) {
      final a = list[i];
      list[i] = ArtistEntry(
        name: a.name,
        plays: a.plays + 1,
        lastPlayedMs: now,
        imageUrl: imageUrl.isNotEmpty ? imageUrl : a.imageUrl,
      );
    } else {
      list.add(ArtistEntry(name: name, plays: 1, lastPlayedMs: now, imageUrl: imageUrl));
    }
    var sorted = _sorted(list);
    if (sorted.length > _maxArtists) sorted = sorted.sublist(0, _maxArtists);
    artists.value = sorted;
  }

  Future<void> clear() async {
    tracks.value = const [];
    artists.value = const [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
    await prefs.remove(_artistKey);
  }
}
