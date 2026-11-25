import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_taglib/flutter_taglib.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../models/track_model.dart';
import 'audio_url_resolver.dart';
import 'data_merge.dart';
import 'lyrics_service.dart';
import 'playlist_service.dart';
import 'secure_prefs.dart';
import 'vault.dart';

class DownloadedItem {
  final Track track;
  final String path;
  final int bytes;
  final int atMs;
  final String coverPath;

  const DownloadedItem({
    required this.track,
    required this.path,
    required this.bytes,
    required this.atMs,
    this.coverPath = '',
  });

  Map<String, dynamic> toJson() => {
        'track': track.toJson(),
        'path': path,
        'bytes': bytes,
        'at': atMs,
        'cover': coverPath,
      };

  static DownloadedItem? fromJson(Map<String, dynamic> m) {
    try {
      return DownloadedItem(
        track: Track.fromJson(m['track'] as Map<String, dynamic>),
        path: m['path'] as String,
        bytes: (m['bytes'] as num).toInt(),
        atMs: (m['at'] as num).toInt(),
        coverPath: (m['cover'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

enum DownloadStatus { queued, active, failed }

class DownloadTask {
  final Track track;
  final DownloadStatus status;
  final double progress;
  final String? error;

  const DownloadTask(this.track,
      {this.status = DownloadStatus.queued, this.progress = 0, this.error});

  DownloadTask copy({DownloadStatus? status, double? progress, String? error}) =>
      DownloadTask(track,
          status: status ?? this.status,
          progress: progress ?? this.progress,
          error: error);
}

class DownloadEvent {
  final Track track;
  final bool ok;
  final int seq;
  const DownloadEvent(this.track, this.ok, this.seq);
}

class _Cancelled implements Exception {}

class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const String _dirKey = 'download_dir_v1';
  static const String _vaultName = 'downloads';
  static const int _chunk = 2 * 1024 * 1024;

  final ValueNotifier<Map<String, DownloadedItem>> items =
      ValueNotifier<Map<String, DownloadedItem>>(const {});

  final ValueNotifier<Map<String, DownloadTask>> tasks =
      ValueNotifier<Map<String, DownloadTask>>(const {});

  final ValueNotifier<DownloadEvent?> lastEvent = ValueNotifier<DownloadEvent?>(null);
  int _eventSeq = 0;

  final ValueNotifier<String> folder = ValueNotifier<String>('');

  final ValueNotifier<bool> customFolder = ValueNotifier<bool>(false);

  late Directory _support;
  bool _started = false;
  String? _custom;

  // Saved entries whose file is not there right now. They are not shown, but
  // they stay in the saved list so a drive that comes back brings them back.
  List<Map<String, dynamic>> _kept = <Map<String, dynamic>>[];
  final List<String> _queue = [];
  final Set<String> _cancelled = {};
  bool _working = false;
  final Map<String, String> _coverByUrl = {};
  final Map<String, String> _coverById = {};

  Future<void> init() async {
    _support = await getApplicationSupportDirectory();
    try {
      final prefs = await SecurePrefs.getInstance();
      final c = prefs.getString(_dirKey);
      _custom = (c == null || c.isEmpty) ? null : c;
    } catch (_) {}
    String? text;
    var readable = true;
    try {
      final old = File('${_support.path}${Platform.pathSeparator}downloads.json');
      text = await Vault.instance.readTextOrMove(
        _vaultName,
        old,
        isValid: Vault.isJsonList,
        merge: DataMerge.downloads,
      );
    } catch (e) {
      // Not knowing what is saved is not the same as nothing being saved, so
      // nothing is saved over it.
      debugPrint('downloads could not be fetched: $e');
      readable = false;
      Vault.instance.noteUnreadable('list of downloads');
    }
    if (text != null) {
      try {
        final out = <String, DownloadedItem>{};
        final kept = <Map<String, dynamic>>[];
        for (final e in json.decode(text) as List<dynamic>) {
          final entry = e as Map<String, dynamic>;
          final it = DownloadedItem.fromJson(entry);
          if (it != null && File(it.path).existsSync()) {
            out[it.track.id] = it;
          } else {
            // The file may only be out of reach for now (a memory card or a
            // drive that is not connected), so the entry stays in the saved
            // list and comes back by itself when the file does.
            kept.add(entry);
          }
        }
        _kept = kept;
        items.value = out;
      } catch (e) {
        debugPrint('downloads load failed: $e');
        readable = false;
        Vault.instance.noteUnreadable('list of downloads');
      }
    }
    _started = readable;
    _publishFolder();
    _reindexCovers();
    items.addListener(_reindexCovers);
    await _syncPlaylist();
  }

  void _reindexCovers() {
    _coverByUrl.clear();
    _coverById.clear();
    for (final it in items.value.values) {
      if (it.coverPath.isEmpty || !File(it.coverPath).existsSync()) continue;
      if (it.track.imageUrl.isNotEmpty) _coverByUrl[it.track.imageUrl] = it.coverPath;
      _coverById[it.track.id] = it.coverPath;
    }
  }

  String? coverFor(String url) => _coverByUrl[url];

  String? coverPathOf(String trackId) => _coverById[trackId];

  void _publishFolder() {
    folder.value = _custom ?? '${_support.path}/downloads';
    customFolder.value = _custom != null;
  }

  Future<void> _syncPlaylist() async {
    // With a list of downloads that could not be read nothing is known about
    // what is downloaded, so the playlist is left as it is.
    if (!_started) return;
    final ps = PlaylistService.instance;
    final pl = ps.byId(PlaylistService.downloadsId);
    if (pl == null) return;
    final have = pl.tracks.map((t) => t.id).toSet();
    // A song whose file is only out of reach for now stays in the playlist.
    final away = <String>{
      for (final m in _kept)
        if (_idOf(m) != null) _idOf(m)!,
    };
    for (final id in have) {
      if (!items.value.containsKey(id) && !away.contains(id)) {
        await ps.removeTrack(PlaylistService.downloadsId, id);
      }
    }
    final sorted = items.value.values.toList()..sort((a, b) => a.atMs.compareTo(b.atMs));
    for (final it in sorted) {
      if (!have.contains(it.track.id)) await ps.addTrack(PlaylistService.downloadsId, it.track);
    }
  }

  bool isDownloaded(String id) => items.value.containsKey(id);

  String? localPath(String id) {
    final it = items.value[id];
    if (it == null) return null;
    return File(it.path).existsSync() ? it.path : null;
  }

  Future<String?> setFolder(String? path) async {
    if (path != null) {
      try {
        final d = Directory(path);
        if (!await d.exists()) await d.create(recursive: true);
        final probe = File('${d.path}/.xtify_write_test');
        await probe.writeAsString('ok');
        await probe.delete();
      } catch (e) {
        debugPrint('download folder not writable: $e');
        return 'Xtify cannot save files to that folder. Pick a different one.';
      }
    }
    _custom = path;
    try {
      final prefs = await SecurePrefs.getInstance();
      if (path == null) {
        await prefs.remove(_dirKey);
      } else {
        await prefs.setString(_dirKey, path);
      }
    } catch (_) {}
    _publishFolder();
    return null;
  }

  Future<Directory> _dir() async {
    final d = Directory(folder.value);
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  void enqueue(Track t) {
    if (!t.isPlayable || isDownloaded(t.id)) return;
    final cur = tasks.value[t.id];
    if (cur != null && cur.status != DownloadStatus.failed) return;
    _setTask(t.id, DownloadTask(t));
    _queue.add(t.id);
    _pump();
  }

  void enqueueAll(Iterable<Track> list) {
    for (final t in list) {
      enqueue(t);
    }
  }

  void cancel(String id) {
    final t = tasks.value[id];
    if (t == null) return;
    _queue.remove(id);
    if (t.status == DownloadStatus.active) {
      _cancelled.add(id);
    } else {
      _setTask(id, null);
    }
  }

  Future<void> remove(String id) async {
    final it = items.value[id];
    if (it != null) {
      try {
        final f = File(it.path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('could not delete ${it.path}: $e');
      }
      if (it.coverPath.isNotEmpty) {
        try {
          final c = File(it.coverPath);
          if (await c.exists()) await c.delete();
        } catch (_) {}
      }
      final next = {...items.value}..remove(id);
      items.value = next;
      await _saveItems();
    }
    await LyricsService.instance.forget(id);
    await PlaylistService.instance.removeTrack(PlaylistService.downloadsId, id);
  }

  void _setTask(String id, DownloadTask? t) {
    final m = {...tasks.value};
    if (t == null) {
      m.remove(id);
    } else {
      m[id] = t;
    }
    tasks.value = m;
  }

  Future<void> _saveItems() async {
    if (!_started) return;
    try {
      final saved = await Vault.instance.writeText(
        _vaultName,
        json.encode([
          for (final e in items.value.values) e.toJson(),
          for (final m in _kept)
            if (!items.value.containsKey(_idOf(m))) m,
        ]),
      );
      if (!saved) debugPrint('downloads save failed: the secure store is not available');
    } catch (e) {
      debugPrint('downloads save failed: $e');
    }
  }

  static String? _idOf(Map<String, dynamic> entry) {
    final track = entry['track'];
    return track is Map && track['id'] != null ? '${track['id']}' : null;
  }

  Future<void> _pump() async {
    if (_working) return;
    _working = true;
    try {
      while (_queue.isNotEmpty) {
        final id = _queue.removeAt(0);
        final task = tasks.value[id];
        if (task == null) continue;
        _setTask(id, task.copy(status: DownloadStatus.active, progress: 0));
        try {
          await _download(task.track);
          _setTask(id, null);
          lastEvent.value = DownloadEvent(task.track, true, ++_eventSeq);
        } on _Cancelled {
          _setTask(id, null);
        } catch (e) {
          debugPrint('download failed for ${task.track.id}: $e');
          _setTask(id, task.copy(status: DownloadStatus.failed, error: '$e'));
          lastEvent.value = DownloadEvent(task.track, false, ++_eventSeq);
        } finally {
          _cancelled.remove(id);
        }
      }
    } finally {
      _working = false;
    }
  }

  Future<void> _download(Track t) async {
    final dir = await _dir();
    final lyrics = LyricsService.instance.load(LyricsQuery.ofTrack(t));
    for (var i = 0;
        i < 60 && AudioUrlResolver.isBusy && !AudioUrlResolver.canLookUpDirectly(t.id);
        i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    final errors = <String>[];

    Future<String?> attempt(ResolvedAudioUrl r, String label) async {
      try {
        return await _fetchFile(t, r, dir);
      } on _Cancelled {
        rethrow;
      } catch (e) {
        errors.add('$label: $e');
        debugPrint('download attempt failed ($label): $e');
        return null;
      }
    }

    String? path;
    final cached = AudioUrlResolver.cached(t.id);
    if (cached != null) {
      path = await attempt(cached, 'cached');
      if (path == null) AudioUrlResolver.clearCache(t.id);
    }
    for (final idx in AudioUrlResolver.attemptOrder(t.id)) {
      if (path != null) break;
      final label = AudioUrlResolver.strategyLabel(idx);
      ResolvedAudioUrl r;
      try {
        r = await AudioUrlResolver().resolve(t.id, strategyIndex: idx, background: true);
      } catch (e) {
        errors.add('$label: $e');
        if (e is TimeoutException) break;
        continue;
      }
      if (_cancelled.contains(t.id)) throw _Cancelled();
      path = await attempt(r, label);
    }
    if (path == null) throw Exception(errors.join(' | '));

    final found = await lyrics.timeout(
      const Duration(seconds: 25),
      onTimeout: () => const LyricsResult(LyricsStatus.failed),
    );
    await LyricsService.instance.keep(t.id, found);
    final cover = await _writeTags(t, path, LyricsService.plainText(found));

    final len = await File(path).length();
    items.value = {
      ...items.value,
      t.id: DownloadedItem(
        track: t,
        path: path,
        bytes: len,
        atMs: DateTime.now().millisecondsSinceEpoch,
        coverPath: cover,
      ),
    };
    await _saveItems();
    await PlaylistService.instance.addTrack(PlaylistService.downloadsId, t);
  }

  Future<String> _fetchFile(Track t, ResolvedAudioUrl r, Directory dir) async {
    final uri = Uri.parse(r.url);
    final name = _fileName(t, _extension(uri));
    final part = File('${dir.path}/$name.part');
    final out = File('${dir.path}/$name');
    final client = http.Client();
    RandomAccessFile? raf;
    var lastShown = 0.0;
    final clock = Stopwatch()..start();
    var lastShownAtMs = -1000;
    try {
      raf = await part.open(mode: FileMode.write);
      int? total = int.tryParse(uri.queryParameters['clen'] ?? '');
      var pos = 0;
      void report(int at) {
        final tot = total;
        if (tot == null || tot <= 0) return;
        final p = (at / tot).clamp(0.0, 1.0);
        if (p <= lastShown) return;
        final due = p >= 1.0 ||
            (p - lastShown >= 0.01 && clock.elapsedMilliseconds - lastShownAtMs >= 200);
        if (!due) return;
        lastShown = p;
        lastShownAtMs = clock.elapsedMilliseconds;
        final cur = tasks.value[t.id];
        if (cur != null) _setTask(t.id, cur.copy(progress: p));
      }

      while (true) {
        if (_cancelled.contains(t.id)) throw _Cancelled();
        final end = (total != null ? min(pos + _chunk, total) : pos + _chunk) - 1;
        final req = http.Request('GET', uri)
          ..headers.addAll({...r.headers, 'Range': 'bytes=$pos-$end'});
        final res = await client.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.stream.drain<void>();
          throw Exception('HTTP ${res.statusCode}');
        }
        if (res.statusCode == 200 && pos != 0) {
          await res.stream.drain<void>();
          throw Exception('server ignored the range');
        }
        if (res.statusCode == 200) {
          total ??= res.contentLength;
        } else {
          total ??= int.tryParse(res.headers['content-range']?.split('/').last ?? '');
        }
        var got = 0;
        await for (final bytes in res.stream.timeout(const Duration(seconds: 30))) {
          if (_cancelled.contains(t.id)) throw _Cancelled();
          await raf.writeFrom(bytes);
          got += bytes.length;
          report(pos + got);
        }
        if (got == 0) throw Exception('empty chunk');
        pos += got;
        if (res.statusCode == 200) {
          total = pos;
          break;
        }
        if (total != null) {
          if (pos >= total) break;
        } else if (got < _chunk) {
          break;
        }
      }
      await raf.close();
      raf = null;
      if (pos < 1024) throw Exception('file too small ($pos bytes)');
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
      return out.path;
    } catch (_) {
      try {
        await raf?.close();
      } catch (_) {}
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<String> _writeTags(Track t, String path, String lyrics) async {
    TagLibFile? file;
    var coverPath = '';
    try {
      Uint8List? cover;
      String mime = 'image/jpeg';
      final url = _bigCover(t.imageUrl);
      if (url != null) {
        try {
          final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
          final type = (res.headers['content-type'] ?? '').toLowerCase();
          if (res.statusCode == 200 && res.bodyBytes.length > 1000) {
            if (type.contains('png')) {
              cover = res.bodyBytes;
              mime = 'image/png';
            } else if (type.contains('jpeg') || type.contains('jpg')) {
              cover = res.bodyBytes;
            }
          }
        } catch (e) {
          debugPrint('cover download failed for ${t.id}: $e');
        }
      }
      if (cover != null) coverPath = await _saveCover(t.id, cover, mime);
      file = await TagLibFile.openAsync(path, writeAccess: true);
      if (file == null) return coverPath;
      if (lyrics.isNotEmpty) {
        final props = <String, List<String>>{...file.properties};
        props[TagProperties.lyrics] = [lyrics];
        file.setProperties(props);
      }
      file.title = t.title;
      if (t.artist.isNotEmpty) file.artist = t.artist;
      if (t.album.isNotEmpty) file.album = t.album;
      if (cover != null) file.setCover(data: cover, mimeType: mime);
      final ok = file.save();
      debugPrint('tags for ${t.id}: ${ok ? 'saved' : 'not saved'}${cover == null ? ', no cover' : ''}${lyrics.isEmpty ? ', no lyrics' : ', with lyrics'}');
    } catch (e) {
      debugPrint('tagging failed for ${t.id}: $e');
    } finally {
      try {
        file?.close();
      } catch (_) {}
    }
    return coverPath;
  }

  Future<String> _saveCover(String id, Uint8List bytes, String mime) async {
    try {
      final dir = Directory('${_support.path}/covers');
      if (!await dir.exists()) await dir.create(recursive: true);
      final f = File('${dir.path}/$id.${mime.contains('png') ? 'png' : 'jpg'}');
      await f.writeAsBytes(bytes);
      return f.path;
    } catch (e) {
      debugPrint('cover save failed for $id: $e');
      return '';
    }
  }

  static String? _bigCover(String url) {
    if (url.isEmpty) return null;
    return url.replaceFirstMapped(RegExp(r'=w\d+-h\d+'), (_) => '=w600-h600');
  }

  static String _extension(Uri u) {
    final mime = u.queryParameters['mime'] ?? '';
    return mime.contains('webm') ? 'webm' : 'm4a';
  }

  static String _fileName(Track t, String ext) {
    String clean(String s) => s
        .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]+'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    var base = t.artist.trim().isEmpty ? t.title : '${t.artist} - ${t.title}';
    base = clean(base);
    if (base.length > 100) base = base.substring(0, 100).trim();
    return '$base [${t.id}].$ext';
  }
}
