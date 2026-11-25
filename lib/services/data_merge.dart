import 'dart:convert';
import 'dart:io';

// Joins the saved data of two versions of Xtify.
//
// It is used when a copy written by an older version turns up next to the
// encrypted data, for example after going back to an older Xtify and updating
// again. That copy was written later, so it holds the newest changes. Nothing
// is dropped: whatever either side has, the result has too.
class DataMerge {
  DataMerge._();

  // Playlists by id. A playlist that both sides have keeps its own details
  // (title and so on) and gets the songs of both.
  static String playlists(String current, String older) => _join(
        current,
        older,
        (m) => m['id'] == null ? null : '${m['id']}',
        (a, b) => <String, dynamic>{...a, 'tracks': _songs(a['tracks'], b['tracks'])},
      );

  // The list of downloads by song id. When both sides know a song, the entry
  // whose file is still there wins, and the saved one if both files are.
  static String downloads(
    String current,
    String older, {
    bool Function(String path)? exists,
  }) {
    final has = exists ?? _fileExists;
    return _join(
      current,
      older,
      _downloadId,
      (a, b) => has('${a['path']}') || !has('${b['path']}') ? a : b,
    );
  }

  // Import reports by id. A report never changes once it is finished.
  static String reports(String current, String older) => _join(
        current,
        older,
        (m) => m['id'] == null ? null : '${m['id']}',
        (a, b) => a,
      );

  // The three lists below are rolling windows, and [keep] is the same limit the
  // store applies the next time something is added to them.

  // Recently played songs, newest first. The older version played them later,
  // so they go on top.
  static List<String> history(List<String> current, List<String> older, {int keep = 30}) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in [...older, ...current]) {
      final id = _songId(raw);
      if (id == null || seen.add(id)) out.add(raw);
    }
    return out.take(keep).toList();
  }

  // Search history, newest first.
  static List<String> queries(List<String> current, List<String> older, {int keep = 15}) {
    final seen = <String>{};
    return [
      for (final q in [...older, ...current])
        if (seen.add(q.trim().toLowerCase())) q,
    ].take(keep).toList();
  }

  // Play counts per artist. The counts add up, the latest play and its picture win.
  static List<String> artistStats(List<String> current, List<String> older, {int keep = 100}) {
    final byName = <String, Map<String, dynamic>>{};
    final loose = <String>[];
    for (final raw in [...current, ...older]) {
      Map<String, dynamic>? item;
      try {
        final m = jsonDecode(raw);
        if (m is Map) item = Map<String, dynamic>.from(m);
      } catch (_) {}
      final name = item == null ? '' : '${item['name'] ?? ''}'.trim().toLowerCase();
      if (item == null || name.isEmpty) {
        loose.add(raw);
        continue;
      }
      final have = byName[name];
      byName[name] = have == null ? item : _joinArtist(have, item);
    }
    final list = byName.values.toList()
      ..sort((a, b) {
        final plays = _int(b['plays']).compareTo(_int(a['plays']));
        return plays != 0 ? plays : _int(b['last']).compareTo(_int(a['last']));
      });
    return [for (final m in list) jsonEncode(m), ...loose].take(keep).toList();
  }

  static Map<String, dynamic> _joinArtist(Map<String, dynamic> a, Map<String, dynamic> b) {
    final newest = _int(b['last']) > _int(a['last']) ? b : a;
    final other = identical(newest, a) ? b : a;
    final picture = '${newest['img'] ?? ''}'.isNotEmpty ? newest['img'] : other['img'];
    return <String, dynamic>{
      ...newest,
      'plays': _int(a['plays']) + _int(b['plays']),
      'last': newest['last'] ?? 0,
      'img': picture ?? '',
    };
  }

  // Two JSON lists of objects. Items of [older] that [current] does not have
  // are added at the end, an item both have is combined by [combine].
  static String _join(
    String current,
    String older,
    String? Function(Map<String, dynamic> item) idOf,
    Map<String, dynamic> Function(Map<String, dynamic> current, Map<String, dynamic> older)
        combine,
  ) {
    final into = jsonDecode(current);
    final from = jsonDecode(older);
    if (into is! List || from is! List) throw const FormatException('expected two lists');
    final out = <dynamic>[...into];
    final at = <String, int>{};
    for (var i = 0; i < out.length; i++) {
      final item = out[i];
      if (item is! Map) continue;
      final id = idOf(Map<String, dynamic>.from(item));
      if (id != null) at.putIfAbsent(id, () => i);
    }
    for (final raw in from) {
      if (raw is! Map) continue;
      final item = Map<String, dynamic>.from(raw);
      final id = idOf(item);
      final i = id == null ? null : at[id];
      if (id == null || i == null) {
        if (id != null) at[id] = out.length;
        out.add(item);
      } else {
        out[i] = combine(Map<String, dynamic>.from(out[i] as Map), item);
      }
    }
    return jsonEncode(out);
  }

  static List<dynamic> _songs(Object? current, Object? older) {
    final out = <dynamic>[if (current is List) ...current];
    final seen = <String>{
      for (final t in out)
        if (t is Map) '${t['id']}',
    };
    if (older is List) {
      for (final t in older) {
        if (t is Map && seen.add('${t['id']}')) out.add(t);
      }
    }
    return out;
  }

  static String? _downloadId(Map<String, dynamic> m) {
    final track = m['track'];
    if (track is! Map || track['id'] == null) return null;
    return '${track['id']}';
  }

  static String? _songId(String raw) {
    try {
      final m = jsonDecode(raw);
      return m is Map && m['id'] != null ? '${m['id']}' : null;
    } catch (_) {
      return null;
    }
  }

  static bool _fileExists(String path) {
    try {
      return File(path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}
