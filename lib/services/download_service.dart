import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_taglib/flutter_taglib.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track_model.dart';
import 'audio_url_resolver.dart';
import 'playlist_service.dart';

/// A song that is saved on the phone.
class DownloadedItem {
  final Track track;
  final String path;
  final int bytes;
  final int atMs;

  const DownloadedItem({
    required this.track,
    required this.path,
    required this.bytes,
    required this.atMs,
  });

  Map<String, dynamic> toJson() => {
        'track': track.toJson(),
        'path': path,
        'bytes': bytes,
        'at': atMs,
      };

  static DownloadedItem? fromJson(Map<String, dynamic> m) {
    try {
      return DownloadedItem(
        track: Track.fromJson(m['track'] as Map<String, dynamic>),
        path: m['path'] as String,
        bytes: (m['bytes'] as num).toInt(),
        atMs: (m['at'] as num).toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

enum DownloadStatus { queued, active, failed }

/// A download that is waiting, running or has failed.
class DownloadTask {
  final Track track;
  final DownloadStatus status;
  final double progress; // 0..1, only meaningful while active
  final String? error;

  const DownloadTask(this.track,
      {this.status = DownloadStatus.queued, this.progress = 0, this.error});

  DownloadTask copy({DownloadStatus? status, double? progress, String? error}) =>
      DownloadTask(track,
          status: status ?? this.status,
          progress: progress ?? this.progress,
          error: error);
}

/// A finished (or failed) download, for the "Saved" / "Failed" banner.
class DownloadEvent {
  final Track track;
  final bool ok;
  final int seq; // changes on every event so the same song can fire twice
  const DownloadEvent(this.track, this.ok, this.seq);
}

class _Cancelled implements Exception {}

/// Saves songs as audio files and keeps the built-in "Downloads" playlist in step.
///
/// Files go to the app's own folder unless the user picks another one. Songs that
/// were already downloaded stay where they were if the folder is changed later.
class DownloadService {
  DownloadService._();
  static final DownloadService instance = DownloadService._();

  static const String _dirKey = 'download_dir_v1';
  static const int _chunk = 2 * 1024 * 1024; // YouTube throttles one big request

  /// trackId -> saved song.
  final ValueNotifier<Map<String, DownloadedItem>> items =
      ValueNotifier<Map<String, DownloadedItem>>(const {});

  /// trackId -> waiting / running / failed download.
  final ValueNotifier<Map<String, DownloadTask>> tasks =
      ValueNotifier<Map<String, DownloadTask>>(const {});

  /// The latest finished or failed download.
  final ValueNotifier<DownloadEvent?> lastEvent = ValueNotifier<DownloadEvent?>(null);
  int _eventSeq = 0;

  /// Folder new downloads go to (for showing in the UI).
  final ValueNotifier<String> folder = ValueNotifier<String>('');

  /// True while the user has chosen their own folder.
  final ValueNotifier<bool> customFolder = ValueNotifier<bool>(false);

  late Directory _support;
  File? _file;
  String? _custom;
  final List<String> _queue = [];
  final Set<String> _cancelled = {};
  bool _working = false;

  Future<void> init() async {
    _support = await getApplicationSupportDirectory();
    _file = File('${_support.path}/downloads.json');
    try {
      final prefs = await SharedPreferences.getInstance();
      final c = prefs.getString(_dirKey);
      _custom = (c == null || c.isEmpty) ? null : c;
    } catch (_) {}
    try {
      if (await _file!.exists()) {
        final out = <String, DownloadedItem>{};
        for (final e in json.decode(await _file!.readAsString()) as List<dynamic>) {
          final it = DownloadedItem.fromJson(e as Map<String, dynamic>);
          // files deleted outside the app are dropped
          if (it != null && File(it.path).existsSync()) out[it.track.id] = it;
        }
        items.value = out;
      }
    } catch (e) {
      debugPrint('downloads load failed: $e');
    }
    _publishFolder();
    await _syncPlaylist();
  }

  void _publishFolder() {
    folder.value = _custom ?? '${_support.path}/downloads';
    customFolder.value = _custom != null;
  }

  /// Makes the Downloads playlist match what is on the phone.
  Future<void> _syncPlaylist() async {
    final ps = PlaylistService.instance;
    final pl = ps.byId(PlaylistService.downloadsId);
    if (pl == null) return;
    final have = pl.tracks.map((t) => t.id).toSet();
    for (final id in have) {
      if (!items.value.containsKey(id)) await ps.removeTrack(PlaylistService.downloadsId, id);
    }
    final sorted = items.value.values.toList()..sort((a, b) => a.atMs.compareTo(b.atMs));
    for (final it in sorted) {
      if (!have.contains(it.track.id)) await ps.addTrack(PlaylistService.downloadsId, it.track);
    }
  }

  // ---------------- queries ----------------

  bool isDownloaded(String id) => items.value.containsKey(id);

  /// Path of the saved file, or null when it is not saved (or was deleted).
  String? localPath(String id) {
    final it = items.value[id];
    if (it == null) return null;
    return File(it.path).existsSync() ? it.path : null;
  }

  // ---------------- folder ----------------

  /// Sets the folder for new downloads; null goes back to the app's own folder.
  /// Returns an error message, or null on success.
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
      final prefs = await SharedPreferences.getInstance();
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

  // ---------------- actions ----------------

  /// Adds a song to the download queue (also retries a failed one).
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

  /// Stops a waiting or running download, or clears a failed one.
  void cancel(String id) {
    final t = tasks.value[id];
    if (t == null) return;
    _queue.remove(id);
    if (t.status == DownloadStatus.active) {
      _cancelled.add(id); // the worker notices between chunks
    } else {
      _setTask(id, null);
    }
  }

  /// Deletes the saved file and takes the song out of Downloads.
  Future<void> remove(String id) async {
    final it = items.value[id];
    if (it != null) {
      try {
        final f = File(it.path);
        if (await f.exists()) await f.delete();
      } catch (e) {
        debugPrint('could not delete ${it.path}: $e');
      }
      final next = {...items.value}..remove(id);
      items.value = next;
      await _saveItems();
    }
    await PlaylistService.instance.removeTrack(PlaylistService.downloadsId, id);
  }

  // ---------------- state helpers ----------------

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
    final f = _file;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
          json.encode(items.value.values.map((e) => e.toJson()).toList()));
      await tmp.rename(f.path);
    } catch (e) {
      debugPrint('downloads save failed: $e');
    }
  }

  // ---------------- the worker ----------------

  /// One download at a time: it is gentler on the phone and on YouTube.
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
    // a song the user is playing right now goes first
    for (var i = 0; i < 60 && AudioUrlResolver.isBusy; i++) {
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
    final n = AudioUrlResolver.strategyCount;
    for (var k = 0; path == null && k < n; k++) {
      final idx = (AudioUrlResolver.preferredStrategy + k) % n;
      final label = AudioUrlResolver.strategyLabel(idx);
      ResolvedAudioUrl r;
      try {
        r = await AudioUrlResolver().resolve(t.id, strategyIndex: idx);
      } catch (e) {
        errors.add('$label: $e');
        if (e is TimeoutException) break;
        continue;
      }
      if (_cancelled.contains(t.id)) throw _Cancelled();
      path = await attempt(r, label);
    }
    if (path == null) throw Exception(errors.join(' | '));

    // title, artist and cover go inside the file so other players show them
    await _writeTags(t, path);

    final len = await File(path).length();
    items.value = {
      ...items.value,
      t.id: DownloadedItem(
        track: t,
        path: path,
        bytes: len,
        atMs: DateTime.now().millisecondsSinceEpoch,
      ),
    };
    await _saveItems();
    await PlaylistService.instance.addTrack(PlaylistService.downloadsId, t);
  }

  /// Downloads [r] in ranged chunks into a .part file, then renames it. Returns the path.
  Future<String> _fetchFile(Track t, ResolvedAudioUrl r, Directory dir) async {
    final uri = Uri.parse(r.url);
    final name = _fileName(t, _extension(uri));
    final part = File('${dir.path}/$name.part');
    final out = File('${dir.path}/$name');
    final client = http.Client();
    RandomAccessFile? raf;
    var lastShown = 0.0;
    try {
      raf = await part.open(mode: FileMode.write);
      int? total = int.tryParse(uri.queryParameters['clen'] ?? '');
      var pos = 0;
      void report(int at) {
        final tot = total;
        if (tot == null || tot <= 0) return;
        final p = (at / tot).clamp(0.0, 1.0);
        if (p - lastShown >= 0.005) {
          lastShown = p;
          final cur = tasks.value[t.id];
          if (cur != null) _setTask(t.id, cur.copy(progress: p));
        }
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
          // the server ignored the range and sends everything
          total ??= res.contentLength;
        } else {
          total ??= int.tryParse(res.headers['content-range']?.split('/').last ?? '');
        }
        var got = 0;
        await for (final bytes in res.stream.timeout(const Duration(seconds: 30))) {
          if (_cancelled.contains(t.id)) throw _Cancelled();
          await raf.writeFrom(bytes);
          got += bytes.length;
          report(pos + got); // smooth progress: updates as the bytes arrive
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
          break; // size unknown: a short chunk is the end
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

  /// Writes title / artist / album and the cover into the audio file.
  /// Never fails the download: a song without tags still plays fine.
  Future<void> _writeTags(Track t, String path) async {
    TagLibFile? file;
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
            } // webp and others are skipped: m4a covers must be jpeg or png
          }
        } catch (e) {
          debugPrint('cover download failed for ${t.id}: $e');
        }
      }
      file = await TagLibFile.openAsync(path, writeAccess: true);
      if (file == null) return; // format not supported (e.g. webm)
      file.title = t.title;
      if (t.artist.isNotEmpty) file.artist = t.artist;
      if (t.album.isNotEmpty) file.album = t.album;
      if (cover != null) file.setCover(data: cover, mimeType: mime);
      final ok = file.save();
      debugPrint('tags for ${t.id}: ${ok ? 'saved' : 'not saved'}${cover == null ? ', no cover' : ''}');
    } catch (e) {
      debugPrint('tagging failed for ${t.id}: $e');
    } finally {
      try {
        file?.close();
      } catch (_) {}
    }
  }

  /// Asks for a larger picture when the URL is a Google-hosted thumbnail (=w60-h60 style).
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
