import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/track_model.dart';
import 'data_merge.dart';
import 'playlist_service.dart';
import 'playlist_source.dart';
import 'spotify_reader.dart';
import 'track_matcher.dart';
import 'vault.dart';
import 'youtube_api.dart';
import 'youtube_playlist_reader.dart';

enum ImportPhase { queued, reading, matching, done, failed }

class FailedSong {
  final String label;
  final String reason;

  const FailedSong(this.label, this.reason);

  Map<String, dynamic> toJson() => <String, dynamic>{'label': label, 'reason': reason};

  static FailedSong fromJson(Map<String, dynamic> m) => FailedSong(
        (m['label'] as String?) ?? '',
        (m['reason'] as String?) ?? '',
      );
}

class ImportJob extends ChangeNotifier {
  final String id;
  final PlaylistLink link;
  final DateTime startedAt;
  final List<FailedSong> failed;

  String title;
  ImportPhase phase;
  int total;
  int processed;
  int imported;
  int duplicates;
  int hidden;
  String note;
  String problem;
  String? playlistId;
  bool stopRequested = false;

  ImportJob({
    required this.id,
    required this.link,
    required this.startedAt,
    this.title = '',
    this.phase = ImportPhase.queued,
    this.total = 0,
    this.processed = 0,
    this.imported = 0,
    this.duplicates = 0,
    this.hidden = 0,
    this.note = '',
    this.problem = '',
    this.playlistId,
    List<FailedSong>? failed,
  }) : failed = failed ?? <FailedSong>[];

  bool get active =>
      phase == ImportPhase.queued ||
      phase == ImportPhase.reading ||
      phase == ImportPhase.matching;

  int get notTried => max(0, total - processed);

  double? get progress {
    if (phase == ImportPhase.matching && total > 0) return processed / total;
    if (phase == ImportPhase.done) return 1;
    return null;
  }

  void changed() => notifyListeners();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'source': link.source.name,
        'sourceId': link.id,
        'at': startedAt.millisecondsSinceEpoch,
        'title': title,
        'phase': phase.name,
        'total': total,
        'processed': processed,
        'imported': imported,
        'duplicates': duplicates,
        'hidden': hidden,
        'note': note,
        'problem': problem,
        'playlistId': playlistId,
        'failed': failed.map((f) => f.toJson()).toList(),
      };

  static ImportJob? fromJson(Map<String, dynamic> m) {
    try {
      final phase = ImportPhase.values.byName(m['phase'] as String);
      if (phase != ImportPhase.done && phase != ImportPhase.failed) return null;
      return ImportJob(
        id: m['id'] as String,
        link: PlaylistLink(
          PlaylistSource.values.byName(m['source'] as String),
          m['sourceId'] as String,
        ),
        startedAt: DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()),
        title: (m['title'] as String?) ?? '',
        phase: phase,
        total: (m['total'] as num?)?.toInt() ?? 0,
        processed: (m['processed'] as num?)?.toInt() ?? 0,
        imported: (m['imported'] as num?)?.toInt() ?? 0,
        duplicates: (m['duplicates'] as num?)?.toInt() ?? 0,
        hidden: (m['hidden'] as num?)?.toInt() ?? 0,
        note: (m['note'] as String?) ?? '',
        problem: (m['problem'] as String?) ?? '',
        playlistId: m['playlistId'] as String?,
        failed: <FailedSong>[
          for (final e in (m['failed'] as List<dynamic>? ?? const <dynamic>[]))
            FailedSong.fromJson(e as Map<String, dynamic>),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

class PlaylistImportService {
  PlaylistImportService._();
  static final PlaylistImportService instance = PlaylistImportService._();

  static const int _keepReports = 20;
  static const int _flushEvery = 8;
  static const int _giveUpAfter = 8;

  final ValueNotifier<List<ImportJob>> jobs = ValueNotifier<List<ImportJob>>(const []);

  static const String _vaultName = 'import-reports';
  bool _started = false;
  bool _running = false;

  // Saved reports that this version cannot show, for example ones a newer
  // version wrote. They stay in the saved list.
  List<Map<String, dynamic>> _kept = <Map<String, dynamic>>[];

  Future<void> init() async {
    String? text;
    var readable = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final old = File('${dir.path}${Platform.pathSeparator}import_reports.json');
      text = await Vault.instance.readTextOrMove(
        _vaultName,
        old,
        isValid: Vault.isJsonList,
        merge: DataMerge.reports,
      );
    } catch (e) {
      // Not knowing what is saved is not the same as nothing being saved, so
      // nothing is saved over it.
      debugPrint('import reports could not be fetched: $e');
      readable = false;
      Vault.instance.noteUnreadable('import reports');
    }
    if (text != null) {
      try {
        final data = json.decode(text) as List<dynamic>;
        final loaded = <ImportJob>[];
        final kept = <Map<String, dynamic>>[];
        for (final e in data) {
          final entry = e as Map<String, dynamic>;
          final job = ImportJob.fromJson(entry);
          if (job != null) {
            loaded.add(job);
          } else if (kept.length < _keepReports) {
            kept.add(entry);
          }
        }
        _kept = kept;
        jobs.value = loaded;
      } catch (e) {
        // Saved data that cannot be read is never saved over.
        debugPrint('import reports load failed: $e');
        readable = false;
        Vault.instance.noteUnreadable('import reports');
      }
    }
    _started = readable;
  }

  int add(List<PlaylistLink> links) {
    final stamp = DateTime.now();
    final fresh = <ImportJob>[];
    for (final link in links) {
      final busy = jobs.value.any((j) => j.active && j.link.key == link.key) ||
          fresh.any((j) => j.link.key == link.key);
      if (busy) continue;
      fresh.add(ImportJob(
        id: '${stamp.microsecondsSinceEpoch}_${fresh.length}',
        link: link,
        startedAt: stamp,
      ));
    }
    if (fresh.isEmpty) return 0;
    jobs.value = <ImportJob>[...jobs.value, ...fresh];
    unawaited(_pump());
    return fresh.length;
  }

  void stop(ImportJob job) {
    if (job.phase == ImportPhase.queued) {
      jobs.value = jobs.value.where((j) => j.id != job.id).toList();
      return;
    }
    if (!job.active) return;
    job.stopRequested = true;
    job.changed();
  }

  void remove(ImportJob job) {
    if (job.active) return;
    jobs.value = jobs.value.where((j) => j.id != job.id).toList();
    unawaited(_save());
  }

  void clearFinished() {
    jobs.value = jobs.value.where((j) => j.active).toList();
    unawaited(_save());
  }

  void _touch() {
    jobs.value = List<ImportJob>.of(jobs.value);
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        ImportJob? next;
        for (final j in jobs.value) {
          if (j.phase == ImportPhase.queued) {
            next = j;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _run(ImportJob job) async {
    job.phase = ImportPhase.reading;
    job.changed();
    try {
      final source = await _read(job);
      if (job.stopRequested) {
        job.problem = 'Stopped before anything was imported.';
        job.phase = ImportPhase.failed;
      } else {
        await _import(job, source);
      }
    } on SourceException catch (e) {
      job.problem = e.message;
      job.phase = ImportPhase.failed;
    } catch (e) {
      debugPrint('playlist import failed: $e');
      job.problem = 'Something went wrong while importing this playlist.';
      job.phase = ImportPhase.failed;
    }
    job.changed();
    _touch();
    await _trimAndSave();
  }

  Future<SourcePlaylist> _read(ImportJob job) {
    final link = job.link;
    if (link.source == PlaylistSource.spotify) return SpotifyReader.read(link.id);
    return YouTubePlaylistReader.read(
      link.id,
      onProgress: (found) {
        job.total = found;
        job.changed();
      },
    );
  }

  Future<void> _import(ImportJob job, SourcePlaylist source) async {
    final songs = source.songs;
    final spotify = job.link.source == PlaylistSource.spotify;
    job.title = source.title;
    job.total = songs.length;
    job.hidden = source.hidden;
    job.note = source.note;
    job.processed = 0;
    job.phase = ImportPhase.matching;
    job.changed();

    final created = await PlaylistService.instance.createFrom(
      source.title,
      const <Track>[],
      description: 'Imported from ${job.link.sourceName}',
    );
    job.playlistId = created.id;
    _touch();

    final slots = List<Track?>.filled(songs.length, null);
    var next = 0;
    var streak = 0;
    var sinceFlush = 0;
    var flushing = false;

    Future<void> flush() async {
      final id = job.playlistId;
      if (id == null || flushing) return;
      flushing = true;
      try {
        if (PlaylistService.instance.byId(id) == null) {
          job.stopRequested = true;
        } else {
          await PlaylistService.instance.setTracks(id, _unique(slots));
        }
      } finally {
        flushing = false;
      }
    }

    Future<void> handle(int i) async {
      final song = songs[i];
      if (song.problem.isNotEmpty) {
        job.failed.add(FailedSong(song.label, song.problem));
      } else if (song.videoId.isNotEmpty) {
        slots[i] = _direct(song);
        job.imported++;
      } else {
        try {
          final found = await _match(song, job);
          streak = 0;
          if (found == null) {
            job.failed.add(FailedSong(song.label, 'No matching song found'));
          } else {
            slots[i] = found;
            job.imported++;
          }
        } catch (_) {
          streak++;
          job.failed.add(FailedSong(song.label, 'The search failed'));
          if (streak >= _giveUpAfter) {
            job.problem = 'The connection kept failing, so the import stopped early.';
          }
        }
      }
      job.processed++;
    }

    Future<void> worker() async {
      while (!job.stopRequested && job.problem.isEmpty) {
        final i = next++;
        if (i >= songs.length) return;
        await handle(i);
        job.changed();
        if (++sinceFlush >= _flushEvery) {
          sinceFlush = 0;
          await flush();
        }
        if (spotify) await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }

    await Future.wait(<Future<void>>[
      for (var k = 0; k < (spotify ? 2 : 1); k++) worker(),
    ]);

    final tracks = _unique(slots);
    job.duplicates = job.imported - tracks.length;
    job.imported = tracks.length;
    if (job.stopRequested && job.problem.isEmpty) job.problem = 'Stopped before the end.';
    final id = job.playlistId;
    if (id != null) {
      if (PlaylistService.instance.byId(id) == null) {
        job.playlistId = null;
      } else if (tracks.isEmpty) {
        await PlaylistService.instance.delete(id);
        job.playlistId = null;
      } else {
        await PlaylistService.instance.setTracks(id, tracks);
      }
    }
    job.phase = ImportPhase.done;
  }

  Future<Track?> _match(SourceSong song, ImportJob job) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await TrackMatcher.match(song);
      } catch (e) {
        if (attempt >= 2 || job.stopRequested) rethrow;
        final wait = e is YouTubeApiException && e.throttled ? 10 : 1 + attempt * 2;
        await Future<void>.delayed(Duration(seconds: wait));
      }
    }
  }

  static Track _direct(SourceSong s) => Track.fromJson(<String, dynamic>{
        'id': s.videoId,
        'title': s.title,
        'artist': s.artist,
        'duration': s.seconds > 0 ? s.seconds : null,
      });

  static List<Track> _unique(List<Track?> slots) {
    final seen = <String>{};
    final out = <Track>[];
    for (final t in slots) {
      if (t != null && seen.add(t.id)) out.add(t);
    }
    return out;
  }

  Future<void> _trimAndSave() async {
    final finished = jobs.value.where((j) => !j.active).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (finished.length > _keepReports) {
      final drop = finished.skip(_keepReports).map((j) => j.id).toSet();
      jobs.value = jobs.value.where((j) => !drop.contains(j.id)).toList();
    }
    await _save();
  }

  Future<void> _save() async {
    if (!_started) return;
    try {
      final finished = jobs.value.where((j) => !j.active).toList()
        ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
      final shown = finished.take(_keepReports).toList();
      final ids = <Object?>{for (final j in shown) j.id};
      final saved = await Vault.instance.writeText(
        _vaultName,
        json.encode([
          for (final j in shown) j.toJson(),
          for (final m in _kept)
            if (!ids.contains(m['id'])) m,
        ]),
      );
      if (!saved) debugPrint('import reports save failed: the secure store is not available');
    } catch (e) {
      debugPrint('import reports save failed: $e');
    }
  }
}
