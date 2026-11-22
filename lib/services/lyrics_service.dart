import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/track_model.dart';
import 'artist_credit.dart';
import 'connectivity_service.dart';

enum LyricsStatus { found, notFound, instrumental, offline, busy, failed }

class LyricLine {
  final Duration at;
  final String text;

  const LyricLine(this.at, this.text);
}

class LyricsResult {
  final LyricsStatus status;
  final List<LyricLine> synced;
  final List<String> plain;
  final Duration? wait;

  const LyricsResult(
    this.status, {
    this.synced = const <LyricLine>[],
    this.plain = const <String>[],
    this.wait,
  });

  bool get isSynced => synced.isNotEmpty;

  bool get settled =>
      status == LyricsStatus.found ||
      status == LyricsStatus.notFound ||
      status == LyricsStatus.instrumental;
}

class LyricsQuery {
  final String id;
  final String title;
  final String artist;
  final int seconds;

  const LyricsQuery({
    required this.id,
    required this.title,
    required this.artist,
    this.seconds = 0,
  });

  factory LyricsQuery.ofTrack(Track track) {
    var total = 0;
    for (final part in track.duration.split(':')) {
      final value = int.tryParse(part.trim());
      if (value == null) {
        total = 0;
        break;
      }
      total = total * 60 + value;
    }
    return LyricsQuery(
      id: track.id,
      title: track.title,
      artist: track.artist,
      seconds: total,
    );
  }
}

class _Held {
  final LyricsResult result;
  final DateTime at;

  _Held(this.result) : at = DateTime.now();
}

class _Reply {
  final int code;
  final Object? body;
  final Duration? wait;

  const _Reply(this.code, this.body, this.wait);
}

class LyricsService {
  LyricsService._();
  static final LyricsService instance = LyricsService._();

  static const String _host = 'lrclib.net';
  static const String _cacheName = 'lyrics';
  static const String _savedName = 'lyrics_saved';
  static const String _agent =
      'Xtify/3.5.0 (https://github.com/xmokecursed/xtify)';
  static const int _memoryCap = 40;
  static const int _diskCap = 1000;
  static const int _toleranceSeconds = 8;
  static const Duration _spacing = Duration(milliseconds: 400);
  static const Duration _missTtl = Duration(hours: 24);
  static const Duration _cooldown = Duration(seconds: 60);
  static const Duration _failedCooldown = Duration(seconds: 10);
  static const Duration _timeout = Duration(seconds: 12);

  static final RegExp _noise = RegExp(
    r'[\(\[\{][^\)\]\}]*(?:official|video|audio|lyrics?|visuali[sz]er|\bmv\b|\bhd\b|\b4k\b|remaster)[^\)\]\}]*[\)\]\}]',
    caseSensitive: false,
  );
  static final RegExp _brackets = RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]');
  static final RegExp _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  static final RegExp _lead =
      RegExp(r'^((?:\[\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?\])+)(.*)$');
  static final RegExp _stamp =
      RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final RegExp _offset =
      RegExp(r'^\[offset:\s*([+-]?\d+)\s*\]', caseSensitive: false);
  static final RegExp _wordStamp = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');
  static final RegExp _lineBreak = RegExp(r'\r?\n');

  final Map<String, _Held> _memory = <String, _Held>{};
  final Map<String, Future<LyricsResult>> _running =
      <String, Future<LyricsResult>>{};
  final Map<String, (DateTime, LyricsResult)> _lastTry =
      <String, (DateTime, LyricsResult)>{};
  final math.Random _random = math.Random();
  Future<void> _tail = Future<void>.value();
  DateTime _pausedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, Directory> _dirs = <String, Directory>{};
  final StreamController<String> _stored = StreamController<String>.broadcast();
  int _writes = 0;

  Stream<String> get onStored => _stored.stream;

  LyricsResult? peekNow(String key) => _fresh(key)?.result;

  Future<LyricsResult?> peek(String key) async {
    final held = _fresh(key);
    if (held != null) return held.result;
    final found = await _read(_savedName, key) ?? await _read(_cacheName, key);
    if (found != null) _remember(key, found);
    return found;
  }

  Future<void> keep(String key, LyricsResult result) async {
    if (result.status != LyricsStatus.found &&
        result.status != LyricsStatus.instrumental) {
      return;
    }
    await _write(_savedName, key, result);
  }

  Future<void> forget(String key) async {
    final dir = await _folder(_savedName);
    if (dir == null) return;
    try {
      final file = _fileFor(dir, key);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('lyrics saved copy delete failed: $e');
    }
  }

  static String plainText(LyricsResult result) {
    if (result.status != LyricsStatus.found) return '';
    final lines = result.isSynced
        ? <String>[for (final l in result.synced) l.text]
        : result.plain;
    return lines.join('\n').trim();
  }

  Future<LyricsResult> load(LyricsQuery query, {bool force = false}) {
    final running = _running[query.id];
    if (running != null) return running;
    final job = _serial(() => _resolve(query, force)).whenComplete(() {
      _running.remove(query.id);
    });
    _running[query.id] = job;
    return job;
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final run = _tail.then((_) => work());
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  _Held? _fresh(String key) {
    final held = _memory.remove(key);
    if (held == null) return null;
    if (held.result.status == LyricsStatus.notFound &&
        DateTime.now().difference(held.at) > _missTtl) {
      return null;
    }
    _memory[key] = held;
    return held;
  }

  void _remember(String key, LyricsResult result) {
    _memory.remove(key);
    _memory[key] = _Held(result);
    while (_memory.length > _memoryCap) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<LyricsResult> _resolve(LyricsQuery query, bool force) async {
    final key = query.id;
    try {
      final held = _fresh(key);
      if (held != null &&
          (!force || held.result.status != LyricsStatus.notFound)) {
        return held.result;
      }
      final stored = await _read(_savedName, key) ?? await _read(_cacheName, key);
      if (stored != null && (!force || stored.status != LyricsStatus.notFound)) {
        _remember(key, stored);
        return stored;
      }
      final tried = _lastTry[key];
      if (tried != null) {
        final rest = tried.$2.status == LyricsStatus.failed
            ? _failedCooldown
            : _cooldown;
        if (DateTime.now().difference(tried.$1) < rest) return tried.$2;
      }
      if (!ConnectivityService.instance.online.value) {
        return const LyricsResult(LyricsStatus.offline);
      }
      final blocked = _pausedUntil.difference(DateTime.now());
      if (blocked > Duration.zero) {
        return LyricsResult(LyricsStatus.busy, wait: blocked);
      }
      final result = await _fetch(query);
      if (result.status != LyricsStatus.busy) {
        _lastTry[key] = (DateTime.now(), result);
      }
      if (result.settled) {
        _remember(key, result);
        await _write(_cacheName, key, result);
        if (result.status != LyricsStatus.notFound) _stored.add(key);
      }
      return result;
    } catch (e) {
      debugPrint('lyrics: $e');
      return const LyricsResult(LyricsStatus.failed);
    }
  }

  Future<LyricsResult> _fetch(LyricsQuery query) async {
    final title = _cleanTitle(query.title);
    final names = ArtistCredit.parse(query.artist, title: query.title).main;
    final artist = names.isEmpty ? query.artist.trim() : names.first;
    if (title.isEmpty) return const LyricsResult(LyricsStatus.notFound);
    if (artist.isNotEmpty) {
      final direct = await _call('/api/get', {
        'track_name': title,
        'artist_name': artist,
        if (query.seconds > 0) 'duration': '${query.seconds}',
      });
      final body = direct.body;
      if (direct.code == 200 && body is Map<String, dynamic>) {
        return _fromRecord(body);
      }
      if (direct.code != 404) return _failure(direct);
    }
    final found = await _call('/api/search', {'q': '$title $artist'.trim()});
    if (found.code != 200) return _failure(found);
    final list = found.body;
    if (list is! List<dynamic>) return const LyricsResult(LyricsStatus.failed);
    final best = _pick(list, title, artist, query.seconds);
    if (best == null) return const LyricsResult(LyricsStatus.notFound);
    return _fromRecord(best);
  }

  LyricsResult _failure(_Reply reply) {
    if (reply.code == 429 || reply.code == 503) {
      return LyricsResult(LyricsStatus.busy, wait: reply.wait);
    }
    return const LyricsResult(LyricsStatus.failed);
  }

  Future<_Reply> _call(String path, Map<String, String> params) async {
    final gap = _lastCall.add(_spacing).difference(DateTime.now());
    if (gap > Duration.zero) await Future<void>.delayed(gap);
    _lastCall = DateTime.now();
    try {
      final res = await http.get(
        Uri.https(_host, path, params),
        headers: const {'User-Agent': _agent, 'Accept': 'application/json'},
      ).timeout(_timeout);
      _lastCall = DateTime.now();
      if (res.statusCode == 429 || res.statusCode == 503) {
        final wait = _backoff(res.headers['retry-after']);
        _pausedUntil = DateTime.now().add(wait);
        return _Reply(res.statusCode, null, wait);
      }
      if (res.statusCode != 200) return _Reply(res.statusCode, null, null);
      final type = res.headers['content-type'] ?? '';
      if (!type.contains('json')) return const _Reply(0, null, null);
      return _Reply(200, json.decode(utf8.decode(res.bodyBytes)), null);
    } catch (e) {
      debugPrint('lyrics request failed: $e');
      return const _Reply(0, null, null);
    }
  }

  Duration _backoff(String? header) {
    final asked = int.tryParse((header ?? '').trim()) ?? 30;
    final seconds = math.min(900, math.max(5, asked));
    final jitter = 1 + _random.nextDouble() * 0.3;
    return Duration(milliseconds: (seconds * 1000 * jitter).round());
  }

  Map<String, dynamic>? _pick(
    List<dynamic> list,
    String title,
    String artist,
    int seconds,
  ) {
    final wantTitle = _fold(title);
    final wantArtist = _fold(artist);
    Map<String, dynamic>? best;
    var top = -1;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final name = _fold('${item['trackName'] ?? item['name'] ?? ''}');
      if (!_sameTitle(wantTitle, name)) continue;
      final by = _fold('${item['artistName'] ?? ''}');
      if (wantArtist.isNotEmpty &&
          by.isNotEmpty &&
          !by.contains(wantArtist) &&
          !wantArtist.contains(by)) {
        continue;
      }
      var score = 10;
      final length = item['duration'];
      if (seconds > 0 && length is num) {
        final off = (length - seconds).abs();
        if (off > _toleranceSeconds) continue;
        score += 100 - (off * 5).round();
      }
      if ('${item['syncedLyrics'] ?? ''}'.trim().isNotEmpty) {
        score += 60;
      } else if ('${item['plainLyrics'] ?? ''}'.trim().isNotEmpty) {
        score += 10;
      }
      if (score > top) {
        top = score;
        best = item;
      }
    }
    return best;
  }

  bool _sameTitle(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    final aShort = a.length <= b.length;
    final shorter = aShort ? a : b;
    final longer = aShort ? b : a;
    return longer.startsWith(shorter) && shorter.length * 10 >= longer.length * 6;
  }

  LyricsResult _fromRecord(Map<String, dynamic> record) {
    if (record['instrumental'] == true) {
      return const LyricsResult(LyricsStatus.instrumental);
    }
    final synced = parseLrc('${record['syncedLyrics'] ?? ''}');
    if (synced.isNotEmpty) {
      return LyricsResult(LyricsStatus.found, synced: synced);
    }
    final plain = _plainLines('${record['plainLyrics'] ?? ''}');
    if (plain.isNotEmpty) {
      return LyricsResult(LyricsStatus.found, plain: plain);
    }
    return const LyricsResult(LyricsStatus.notFound);
  }

  static String _cleanTitle(String title) {
    final cleaned =
        title.replaceAll(_noise, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned.isEmpty ? title.trim() : cleaned;
  }

  static String _fold(String text) {
    final stripped = text.replaceAll(_brackets, ' ');
    final base = stripped.trim().isEmpty ? text : stripped;
    return base.toLowerCase().replaceAll(_nonWord, ' ').trim();
  }

  static List<String> _plainLines(String raw) {
    final out = <String>[];
    for (final row in raw.split(_lineBreak)) {
      final line = row.trimRight();
      if (line.isEmpty && (out.isEmpty || out.last.isEmpty)) continue;
      out.add(line);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out;
  }

  static List<LyricLine> parseLrc(String raw) {
    final found = <(int, LyricLine)>[];
    var shift = 0;
    for (final row in raw.split(_lineBreak)) {
      final line = row.trim();
      if (line.isEmpty) continue;
      final tag = _offset.firstMatch(line);
      if (tag != null) {
        shift = int.tryParse(tag.group(1)!) ?? 0;
        continue;
      }
      final lead = _lead.firstMatch(line);
      if (lead == null) continue;
      final text = lead.group(2)!.replaceAll(_wordStamp, '').trim();
      for (final m in _stamp.allMatches(lead.group(1)!)) {
        final minutes = int.parse(m.group(1)!);
        final seconds = int.parse(m.group(2)!);
        final fraction = (m.group(3) ?? '').padRight(3, '0').substring(0, 3);
        final ms = (minutes * 60 + seconds) * 1000 + int.parse(fraction) - shift;
        found.add((found.length, LyricLine(Duration(milliseconds: math.max(0, ms)), text)));
      }
    }
    found.sort((a, b) {
      final order = a.$2.at.compareTo(b.$2.at);
      return order != 0 ? order : a.$1.compareTo(b.$1);
    });
    final out = <LyricLine>[];
    for (final entry in found) {
      final line = entry.$2;
      if (line.text.isEmpty && (out.isEmpty || out.last.text.isEmpty)) continue;
      out.add(line);
    }
    while (out.isNotEmpty && out.last.text.isEmpty) {
      out.removeLast();
    }
    return out;
  }

  Future<Directory?> _folder(String name) async {
    final known = _dirs[name];
    if (known != null) return known;
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}$name');
      if (!await dir.exists()) await dir.create(recursive: true);
      _dirs[name] = dir;
      return dir;
    } catch (e) {
      debugPrint('lyrics cache folder failed: $e');
      return null;
    }
  }

  File _fileFor(Directory dir, String key) {
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return File('${dir.path}${Platform.pathSeparator}$safe.json');
  }

  Future<LyricsResult?> _read(String name, String key) async {
    final dir = await _folder(name);
    if (dir == null) return null;
    try {
      final file = _fileFor(dir, key);
      if (!await file.exists()) return null;
      final data = json.decode(await file.readAsString());
      if (data is! Map<String, dynamic>) return null;
      final kind = data['k'];
      if (kind == 'none') {
        final at = DateTime.fromMillisecondsSinceEpoch(
          (data['t'] as num?)?.toInt() ?? 0,
        );
        if (DateTime.now().difference(at) > _missTtl) return null;
        return const LyricsResult(LyricsStatus.notFound);
      }
      if (kind == 'instrumental') {
        return const LyricsResult(LyricsStatus.instrumental);
      }
      if (kind != 'found') return null;
      final synced = <LyricLine>[
        for (final e in (data['s'] as List<dynamic>? ?? const <dynamic>[]))
          if (e is List<dynamic> && e.length == 2 && e[0] is num)
            LyricLine(Duration(milliseconds: (e[0] as num).toInt()), '${e[1]}'),
      ];
      final plain = <String>[
        for (final e in (data['p'] as List<dynamic>? ?? const <dynamic>[])) '$e',
      ];
      if (synced.isEmpty && plain.isEmpty) return null;
      return LyricsResult(LyricsStatus.found, synced: synced, plain: plain);
    } catch (e) {
      debugPrint('lyrics cache read failed: $e');
      return null;
    }
  }

  Future<void> _write(String name, String key, LyricsResult result) async {
    final dir = await _folder(name);
    if (dir == null) return;
    try {
      final data = <String, Object>{
        'k': switch (result.status) {
          LyricsStatus.found => 'found',
          LyricsStatus.instrumental => 'instrumental',
          _ => 'none',
        },
        't': DateTime.now().millisecondsSinceEpoch,
        's': [
          for (final l in result.synced) [l.at.inMilliseconds, l.text],
        ],
        'p': result.plain,
      };
      await _fileFor(dir, key).writeAsString(json.encode(data));
      if (name == _cacheName && ++_writes % 25 == 1) unawaited(_trim(dir));
    } catch (e) {
      debugPrint('lyrics cache write failed: $e');
    }
  }

  Future<void> _trim(Directory dir) async {
    try {
      final files = <(File, DateTime)>[];
      await for (final entry in dir.list()) {
        if (entry is File) files.add((entry, (await entry.stat()).modified));
      }
      if (files.length <= _diskCap) return;
      files.sort((a, b) => a.$2.compareTo(b.$2));
      for (final old in files.take(files.length - _diskCap)) {
        await old.$1.delete();
      }
    } catch (e) {
      debugPrint('lyrics cache trim failed: $e');
    }
  }
}
