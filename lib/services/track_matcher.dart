import 'dart:math';
import '../models/track_model.dart';
import 'artist_credit.dart';
import 'playlist_source.dart';
import 'youtube_catalog.dart';

class TrackMatcher {
  TrackMatcher._();

  static final RegExp _brackets = RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]');
  static final RegExp _featured =
      RegExp(r'\s*[\(\[]\s*(?:feat|ft|with)\b[^\)\]]*[\)\]]', caseSensitive: false);
  static final RegExp _tail = RegExp(r'\s[-–—]\s.*$');
  static final RegExp _word = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);
  static final RegExp _loud = RegExp(
    r'\b(?:cover|karaoke|reaction|tutorial|nightcore|slowed|sped|reverb|8d|instrumental|mashup|bootleg)\b',
    caseSensitive: false,
  );
  static final RegExp _soft = RegExp(
    r'\b(?:live|remix|acoustic|demo|unplugged)\b',
    caseSensitive: false,
  );

  static Future<Track?> match(SourceSong song) async {
    final names = ArtistCredit.parse(song.artist).names;
    final primary = names.isEmpty ? '' : names.first;
    final plain = song.title.replaceAll(_featured, '').trim();
    final core = _core(song.title);
    var best = _pick(
      song,
      await YouTubeCatalog.songs('$primary $plain'.trim(), limit: 10),
      video: false,
    );
    if (best == null && core != plain) {
      best = _pick(
        song,
        await YouTubeCatalog.songs('$primary $core'.trim(), limit: 10),
        video: false,
      );
    }
    best ??= _pick(
      song,
      await YouTubeCatalog.search('$primary $core'.trim(), limit: 10),
      video: true,
    );
    return best == null ? null : _imported(song, best);
  }

  static Track _imported(SourceSong song, Track found) {
    return Track.fromJson(<String, dynamic>{
      'id': found.id,
      'title': song.title,
      'artist': song.artist.isEmpty ? found.artist : song.artist,
      'album': found.album,
      'duration': found.duration,
      'isExplicit': found.isExplicit,
    });
  }

  static Track? _pick(SourceSong song, List<Track> found, {required bool video}) {
    Track? best;
    var bestScore = -1.0;
    for (final t in found) {
      final s = _evaluate(song, t, video: video);
      if (s > bestScore) {
        best = t;
        bestScore = s;
      }
    }
    return best;
  }

  static double _evaluate(SourceSong song, Track found, {required bool video}) {
    final title = _titleScore(song.title, found.title);
    if (title < 0.75) return -1;
    final known = !ArtistCredit.parse(song.artist).isEmpty;
    final artist = known ? _artistScore(song, found) : 0.5;
    final duration = _durationScore(song.seconds, found.duration);
    if (known && artist < 0.8) {
      final trusted = !video &&
          title >= 0.95 &&
          duration >= 0.9 &&
          _foreign(song.artist) != _foreign(found.artist);
      if (!trusted) return -1;
    }
    if (!known && (title < 0.9 || duration < 0.6)) return -1;
    if (video && (title < 0.85 || duration < 0.2)) return -1;
    final exact = _overlap(_tokens(song.title), _tokens(found.title));
    final total = 0.45 * title +
        0.30 * artist +
        0.25 * duration +
        0.05 * exact -
        _penalty(song.title, found.title);
    return total >= 0.62 ? total : -1;
  }

  static bool _foreign(String s) {
    for (final r in s.runes) {
      if ((r >= 0x370 && r <= 0x1DFF) || r >= 0x2E80) return true;
    }
    return false;
  }

  static double _penalty(String wanted, String found) {
    var p = 0.0;
    if (_loud.hasMatch(found) && !_loud.hasMatch(wanted)) p += 1;
    final inFound = _soft.hasMatch(found);
    if (inFound != _soft.hasMatch(wanted)) p += inFound ? 0.4 : 0.3;
    return p;
  }

  static String _core(String title) {
    final s = title.replaceAll(_brackets, ' ').replaceAll(_tail, '').trim();
    return s.isEmpty ? title.trim() : s;
  }

  static String _squash(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static Set<String> _tokens(String s) =>
      <String>{for (final m in _word.allMatches(s.toLowerCase())) m.group(0)!};

  static double _overlap(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final common = a.intersection(b).length;
    return common / (a.length + b.length - common);
  }

  static double _titleScore(String wanted, String found) {
    final a = _core(wanted);
    final b = _core(found);
    final na = _squash(a);
    final nb = _squash(b);
    if (na.isEmpty || nb.isEmpty) return 0;
    if (na == nb) return 1;
    var best = 0.0;
    if (na.length >= 3 && nb.length >= 3 && (na.contains(nb) || nb.contains(na))) {
      best = 0.6 + 0.35 * min(na.length, nb.length) / max(na.length, nb.length);
    }
    best = max(best, _overlap(_tokens(a), _tokens(b)) * 0.9);
    best = max(best, _overlap(_tokens(wanted), _tokens(found)) * 0.9);
    return best;
  }

  static double _artistScore(SourceSong song, Track found) {
    final want = _names(ArtistCredit.parse(song.artist).names);
    final have = _names(ArtistCredit.of(found).names);
    final inTitle = _squash(found.title);
    for (final w in want) {
      if (have.contains(w)) return 1;
    }
    for (final w in want) {
      if (w.length < 3) continue;
      for (final h in have) {
        if (h.length >= 3 && (w.contains(h) || h.contains(w))) return 0.9;
      }
      if (inTitle.contains(w)) return 0.8;
    }
    return 0;
  }

  static List<String> _names(List<String> names) =>
      <String>[for (final n in names) if (_squash(n).length >= 2) _squash(n)];

  static int _seconds(String d) {
    final parts = d.split(':').map(int.tryParse).toList();
    if (parts.isEmpty || parts.any((x) => x == null)) return 0;
    var total = 0;
    for (final p in parts) {
      total = total * 60 + p!;
    }
    return parts.length >= 2 ? total : 0;
  }

  static double _durationScore(int wanted, String found) {
    final got = _seconds(found);
    if (wanted <= 0 || got <= 0) return 0.4;
    final d = (wanted - got).abs();
    if (d <= 2) return 1;
    if (d <= 5) return 0.9;
    if (d <= 10) return 0.6;
    if (d <= 20) return 0.2;
    if (d <= 40) return -0.3;
    return -1;
  }
}
