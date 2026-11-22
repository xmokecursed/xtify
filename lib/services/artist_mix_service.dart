import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'secure_prefs.dart';
import '../models/track_model.dart';
import 'history_service.dart';
import 'youtube_catalog.dart';

class ArtistMix {
  final String artist;
  final String imageUrl;
  final List<Track> tracks;
  final int updatedAtMs;

  const ArtistMix({
    required this.artist,
    required this.imageUrl,
    required this.tracks,
    required this.updatedAtMs,
  });

  String get title => '$artist Mix';

  Map<String, dynamic> toJson() => {
        'artist': artist,
        'imageUrl': imageUrl,
        'at': updatedAtMs,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      };

  static ArtistMix? fromJson(Map<String, dynamic> m) {
    try {
      return ArtistMix(
        artist: m['artist'] as String,
        imageUrl: (m['imageUrl'] as String?) ?? '',
        updatedAtMs: (m['at'] as num).toInt(),
        tracks: (m['tracks'] as List<dynamic>)
            .map((e) => Track.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }
}

class ArtistMixService {
  ArtistMixService._();
  static final ArtistMixService instance = ArtistMixService._();

  static const String _key = 'artist_mixes_v2';
  static const String _oldKey = 'artist_mixes_v1';
  static const int _maxMixes = 15;
  static const int _minPlays = 2;
  static const int _target = 50;
  static const Duration _ttl = Duration(hours: 12);
  static const Duration _retryAfter = Duration(minutes: 30);

  final ValueNotifier<List<ArtistMix>> mixes = ValueNotifier<List<ArtistMix>>(const []);
  final ValueNotifier<bool> loading = ValueNotifier<bool>(false);

  final Map<String, ArtistMix> _cache = {};
  final Map<String, int> _failedAt = {};
  Timer? _debounce;
  bool _running = false;
  bool _again = false;
  String? _saved;

  static String _k(String artist) => artist.trim().toLowerCase();

  Future<void> init() async {
    try {
      final prefs = await SecurePrefs.getInstance();
      final current = prefs.getString(_key);
      final raw = current ?? prefs.getString(_oldKey);
      _saved = current;
      if (raw != null) {
        for (final e in json.decode(raw) as List<dynamic>) {
          final m = ArtistMix.fromJson(e as Map<String, dynamic>);
          if (m == null) continue;
          _cache[_k(m.artist)] = current != null
              ? m
              : ArtistMix(
                  artist: m.artist,
                  imageUrl: m.imageUrl,
                  tracks: m.tracks,
                  updatedAtMs: 0,
                );
        }
      }
    } catch (_) {}
    _publish();
    HistoryService.instance.artists.addListener(_onHistory);
  }

  void _onHistory() {
    _publish();
    if (HistoryService.instance.artists.value.isEmpty) {
      _cache.clear();
      _save();
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), refresh);
  }

  List<ArtistEntry> _chosenArtists() => HistoryService.instance.artists.value
      .where((a) => a.name.trim().isNotEmpty && a.plays >= _minPlays)
      .take(_maxMixes)
      .toList();

  void _publish() {
    final out = <ArtistMix>[];
    for (final a in _chosenArtists()) {
      final m = _cache[_k(a.name)];
      if (m != null) out.add(m);
    }
    mixes.value = out;
  }

  Future<void> refresh({bool force = false}) async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    loading.value = true;
    var pass = force;
    try {
      do {
        _again = false;
        for (final a in _chosenArtists()) {
          final key = _k(a.name);
          final now = DateTime.now().millisecondsSinceEpoch;
          final have = _cache[key];
          if (!pass && have != null && now - have.updatedAtMs < _ttl.inMilliseconds) continue;
          if (!pass && now - (_failedAt[key] ?? 0) < _retryAfter.inMilliseconds) continue;
          final built = await _build(a);
          if (built == null) {
            _failedAt[key] = DateTime.now().millisecondsSinceEpoch;
          } else {
            _cache[key] = built;
            _publish();
          }
        }
        pass = false;
      } while (_again);
      await _save();
    } finally {
      _running = false;
      loading.value = false;
    }
  }

  Future<void> forget(String trackId) async {
    var changed = false;
    for (final k in _cache.keys.toList()) {
      final m = _cache[k]!;
      if (!m.tracks.any((t) => t.id == trackId)) continue;
      changed = true;
      _cache[k] = ArtistMix(
        artist: m.artist,
        imageUrl: m.imageUrl,
        tracks: m.tracks.where((t) => t.id != trackId).toList(),
        updatedAtMs: m.updatedAtMs,
      );
    }
    if (!changed) return;
    _publish();
    await _save();
  }

  List<Track> _played(String artist) {
    final k = _k(artist);
    return HistoryService.instance.tracks.value
        .where((t) => _k(t.artist) == k || _k(t.artist).contains(k))
        .toList();
  }

  Future<ArtistMix?> _build(ArtistEntry a) async {
    List<Track> fetched = const [];
    try {
      fetched = await YouTubeCatalog.artistSongs(a.name, limit: _target * 2);
    } catch (e) {
      debugPrint('artist mix ${a.name}: songs failed: $e');
    }
    final played = _played(a.name);
    final seen = <String>{for (final t in played) t.id};
    final fresh = fetched.where((t) => t.isPlayable && seen.add(t.id)).toList();
    if (fresh.isEmpty) return null;

    final rnd = Random();
    final rest = [...fresh]..shuffle(rnd);
    final tracks = <Track>[...played, ...rest].take(_target).toList()..shuffle(rnd);
    final image = a.imageUrl.isNotEmpty
        ? a.imageUrl
        : (tracks.map((t) => t.imageUrl).firstWhere((u) => u.isNotEmpty, orElse: () => ''));
    return ArtistMix(
      artist: a.name,
      imageUrl: image,
      tracks: tracks,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _save() async {
    try {
      final keep = _chosenArtists().map((a) => _k(a.name)).toSet();
      _cache.removeWhere((k, _) => !keep.contains(k));
      final text = json.encode(_cache.values.map((m) => m.toJson()).toList());
      if (text == _saved) return;
      final prefs = await SecurePrefs.getInstance();
      if (await prefs.setString(_key, text)) _saved = text;
      await prefs.remove(_oldKey);
    } catch (_) {}
  }
}
