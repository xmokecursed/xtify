import 'dart:async';
import 'dart:io';
import 'package:extractor/extractor.dart';
import 'package:flutter/foundation.dart';
import '../services/cookie_service.dart';
import 'chunked_audio_source.dart' show linkProblem;
import 'cookie_refresh_service.dart';
import '../utils/cache_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ResolvedAudioUrl {
  final String url;
  final Map<String, String> headers;
  ResolvedAudioUrl({required this.url, required this.headers});
}

class _Strategy {
  final String label;
  final String? client; // yt-dlp youtube player_client
  final bool cookies;
  const _Strategy(this.label, this.client, this.cookies);
}

class AudioUrlResolver {
  static final YoutubeDLFlutter _youtubeDL = YoutubeDLFlutter.instance;
  static final CacheUtil _cacheUtil = CacheUtil();
  static Future<void>? _initFuture;

  // Tried in order, starting with the one that last worked.
  static const List<_Strategy> _strategies = [
    // "visionos" is what yt-dlp itself picks on a phone, where there is no JavaScript
    // runtime: it needs no PO token and no player script, so it is quick and its links play to
    // the end. The android_vr and ios clients used here before are gone on purpose: YouTube
    // now cuts their links off after about 1 MiB (a minute of audio) or refuses them, and
    // yt-dlp's own notes say the same.
    _Strategy('visionos', 'visionos', false),
    _Strategy('default', null, false),
    _Strategy('default+cookies', null, true),
    _Strategy('tv+cookies', 'tv', true),
    _Strategy('mweb+cookies', 'mweb', true),
  ];

  static int preferredStrategy = 0;
  // The first run pays for loading yt-dlp, later ones are quicker: a stuck run is cut off
  // after 20 s so the next strategy starts (the first one gets 45 s).
  static bool _warm = false;

  // The plugin runs one yt-dlp at a time on a single thread; a second call just waits in its
  // queue. Waiting here instead keeps the time limit for the run itself (it used to count the
  // wait, so a song picked while another was being looked up timed out), and lets a song the
  // user is waiting for go before the background ones.
  static bool _running = false;
  static int _foregroundWaiting = 0;
  static int _runId = 0;
  static bool get isBusy => _running || _foregroundWaiting > 0;

  // After a block is detected, go straight to cookies for a while.
  static DateTime _cookiesFirstUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static int get strategyCount => _strategies.length;
  static String strategyLabel(int i) => _strategies[i].label;

  static const String _prefKey = 'preferred_strategy_v4';

  static Future<void> loadPreferred() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_prefKey) ?? 0;
    if (v >= 0 && v < _strategies.length) preferredStrategy = v;
  }

  static Future<void> ensureInitialized() => _initFuture ??= _init();

  static Future<void> _init() async {
    final start = DateTime.now();
    // ffmpeg is only needed for converting/merging downloads; we just fetch URLs
    final result = await _youtubeDL.initialize(enableFFmpeg: false); // never throws; check the result
    if (!result.success) {
      _initFuture = null; // allow retry
      throw Exception('yt-dlp init failed: ${result.errorMessage}');
    }
    debugPrint('yt-dlp initialized in ${DateTime.now().difference(start).inMilliseconds}ms');
  }

  // ---------------- yt-dlp version ----------------

  // The yt-dlp that ships inside the app is from Nov 2025 and knows none of the clients that
  // work today. 2026.08.19 is the first release that defaults to "visionos" on a phone (the
  // 2026.07.04 one still defaults to android_vr).
  static const int _minYtDlp = 20260819;
  static const String _verKey = 'yt_dlp_version_v1';
  static const String _lastUpdateKey = 'yt_dlp_last_update'; // also used by YtDlpUpdateService
  static Future<void>? _modernFuture;
  static bool _modernDone = false;
  static DateTime _modernRetryAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 2026.10.26 -> 20261026 (0 when there is no date in [version]).
  static int _dateOf(String? version) {
    final m = RegExp(r'(\d{4})\.(\d{1,2})\.(\d{1,2})').firstMatch(version ?? '');
    if (m == null) return 0;
    return int.parse(m[1]!) * 10000 + int.parse(m[2]!) * 100 + int.parse(m[3]!);
  }

  /// Remembers the yt-dlp version that was installed here, so later starts need not ask for it.
  static Future<void> rememberVersion(String? version) async {
    if (_dateOf(version) == 0) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_verKey, version!);
  }

  /// Makes sure the yt-dlp inside the app is new enough, updating it first if it is not.
  /// Never throws. Costs nothing once a new enough version is on record; if the update cannot
  /// be done (offline), it is tried again 10 minutes later.
  static Future<void> ensureModern() {
    if (_modernDone) return Future<void>.value();
    final running = _modernFuture;
    if (running != null) return running;
    if (DateTime.now().isBefore(_modernRetryAt)) return Future<void>.value();
    return _modernFuture = _checkYtDlp().then((ok) {
      _modernFuture = null;
      if (ok) {
        _modernDone = true;
      } else {
        _modernRetryAt = DateTime.now().add(const Duration(minutes: 10));
      }
    });
  }

  /// True when yt-dlp is new enough (or it cannot be told), false when updating it failed.
  static Future<bool> _checkYtDlp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_dateOf(prefs.getString(_verKey)) >= _minYtDlp) return true;
      final shown =
          (await _youtubeDL.getVersion().timeout(const Duration(seconds: 20))).youtubeDlVersion;
      debugPrint('yt-dlp inside the app: $shown');
      final have = _dateOf(shown);
      if (have == 0) return true; // cannot tell what it is: leave it alone
      if (have >= _minYtDlp) {
        await prefs.setString(_verKey, shown!);
        return true;
      }
      debugPrint('yt-dlp $shown is too old for YouTube now, updating it before the first song');
      final sw = Stopwatch()..start();
      final r = await _youtubeDL.updateYoutubeDL().timeout(const Duration(seconds: 60));
      if (r.status != OperationStatus.success) {
        debugPrint('yt-dlp update failed: ${r.errorMessage}');
        return false;
      }
      debugPrint('yt-dlp updated to ${r.version} in ${sw.elapsedMilliseconds}ms');
      if (_dateOf(r.version) >= _minYtDlp) {
        await prefs.setString(_verKey, r.version!);
        await prefs.setInt(_lastUpdateKey, DateTime.now().millisecondsSinceEpoch);
      }
      return true;
    } catch (e) {
      debugPrint('yt-dlp version check failed: $e');
      return false;
    }
  }

  // ---------------- cache and prefetch ----------------

  static ResolvedAudioUrl? cached(String videoId) {
    final item = _cacheUtil.get(videoId);
    if (item == null) return null;
    final url = item['url'] as String;
    return ResolvedAudioUrl(url: url, headers: const {});
  }

  /// Call only after the URL actually played.
  static void markWorking(String videoId, int strategyIndex, ResolvedAudioUrl r) {
    // a cookie strategy that rescued one song does not become the first choice for the next
    if (!_strategies[strategyIndex].cookies) {
      preferredStrategy = strategyIndex;
      SharedPreferences.getInstance().then((p) => p.setInt(_prefKey, strategyIndex));
    }
    _cacheUtil.put(videoId, {
      'url': r.url,
      'timestamp': 0,
      'expiresIn': _expirySeconds(r.url),
    });
  }

  static void clearCache(String videoId) => _cacheUtil.remove(videoId);

  // Resolved ahead of the tap. Not trusted until a player actually opens it.
  static final Map<String, Future<ResolvedAudioUrl>> _inflight = {};
  static final Map<String, ResolvedAudioUrl> _prefetched = {};

  /// Start resolving in the background so the tap is fast. Safe to call repeatedly.
  static void prefetch(String videoId) {
    if (_prefetched.containsKey(videoId) || _inflight.containsKey(videoId)) return;
    if (cached(videoId) != null) return;
    if (isBusy) return; // never compete with a song the user is waiting for
    final f = AudioUrlResolver()
        .resolve(videoId, strategyIndex: preferredStrategy, background: true);
    _inflight[videoId] = f;
    f
        .then((r) => _prefetched[videoId] = r)
        .catchError((Object e) {
          debugPrint('prefetch failed for $videoId: $e');
        })
        .whenComplete(() => _inflight.remove(videoId));
  }

  /// A prefetched URL, waiting for an in-flight one if needed. Null if none.
  static Future<ResolvedAudioUrl?> takePrefetched(String videoId) async {
    final inflight = _inflight[videoId];
    if (inflight != null) {
      try {
        final r = await inflight;
        _prefetched.remove(videoId);
        return r;
      } catch (_) {
        return null;
      }
    }
    return _prefetched.remove(videoId);
  }

  static int _expirySeconds(String url) {
    final e = int.tryParse(Uri.tryParse(url)?.queryParameters['expire'] ?? '');
    if (e == null) return 1800;
    final left = e - DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
    return left < 60 ? 60 : (left > 21600 ? 21600 : left);
  }

  // ---------------- resolving ----------------

  /// Looks the song up with yt-dlp using strategy [strategyIndex]. [background] = nobody is
  /// waiting for it (prefetch, the next song, a download): a song the user is waiting for
  /// goes first.
  Future<ResolvedAudioUrl> resolve(String videoId,
      {required int strategyIndex, bool background = false}) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) {
      throw Exception('Invalid YouTube video ID');
    }
    await ensureInitialized();
    // a new enough yt-dlp first (only the very first song after an install waits for this)
    await ensureModern().timeout(const Duration(seconds: 45),
        onTimeout: () => debugPrint('yt-dlp update is taking long, going on without it'));

    final s = _strategies[strategyIndex];
    final options = <String, String>{
      // fail fast on a dead connection instead of waiting on yt-dlp's long defaults
      '--socket-timeout': '10',
      '--extractor-retries': '1',
    };
    if (s.client != null) {
      options['--extractor-args'] = 'youtube:player_client=${s.client}';
    }
    // The default client can use cookies during a block window; the other
    // clients are left alone.
    final cookiesFirst =
        s.client == null && DateTime.now().isBefore(_cookiesFirstUntil);
    if (s.cookies || cookiesFirst) {
      final f = await CookieService.instance.cookieFile();
      if (f == null && s.cookies) throw Exception('not signed in (no cookie file)');
      if (f != null) options['--cookies'] = f.path;
    }
    final pageUrl = 'https://www.youtube.com/watch?v=$videoId';
    VideoInfo info;
    try {
      info = await _runYtDlp(videoId, s.label, pageUrl, options, background: background);
    } catch (e) {
      final msg = e.toString();
      final blocked = msg.contains('429') || msg.contains('Sign in to confirm');
      final f = (!options.containsKey('--cookies') && s.client == null && blocked)
          ? await CookieService.instance.cookieFile()
          : null;
      if (f == null) rethrow;
      _cookiesFirstUntil = DateTime.now().add(const Duration(minutes: 10));
      CookieRefreshService.instance.refreshIfOlderThan(const Duration(minutes: 30));
      debugPrint('[$videoId] ${s.label}: blocked, retrying with cookies');
      info = await _runYtDlp(videoId, s.label, pageUrl, {...options, '--cookies': f.path},
          background: background);
    }

    final format = _pickFormat(info);
    final audioUrl = format?.url;
    if (format == null || audioUrl == null) throw Exception('no audio format returned');
    debugPrint('[$videoId] ${s.label}: audio url from ${Uri.parse(audioUrl).host} '
        '(${_describe(format)})');
    final headers = _headersOf(format);
    // YouTube cuts some links off after the first MiB or refuses them: find out now, so the
    // next strategy can be tried, instead of a song that stops after a minute
    final bad = await linkProblem(audioUrl, headers: headers);
    if (bad != null) {
      debugPrint('[$videoId] ${s.label}: link refused, $bad');
      throw Exception('YouTube refuses this link ($bad)');
    }
    return ResolvedAudioUrl(url: audioUrl, headers: headers);
  }

  /// One yt-dlp lookup. Only one runs at a time (see [_running]); the time limit counts from
  /// when this one really starts.
  static Future<VideoInfo> _runYtDlp(
      String videoId, String label, String pageUrl, Map<String, String> options,
      {required bool background}) async {
    final queued = Stopwatch()..start();
    if (!background) _foregroundWaiting++;
    try {
      while (_running || (background && _foregroundWaiting > 0)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      _running = true;
    } finally {
      if (!background) _foregroundWaiting--;
    }
    final run = ++_runId;
    void free() {
      if (_runId == run) _running = false;
    }

    // if the plugin never answers, do not keep every later lookup waiting forever
    final guard = Timer(const Duration(seconds: 90), free);
    final waited = queued.elapsedMilliseconds;
    debugPrint('[$videoId] $label: yt-dlp start'
        '${waited > 300 ? ' (waited ${waited}ms for another lookup)' : ''}');
    final sw = Stopwatch()..start();
    final call = _youtubeDL.getVideoInfoWithOptions(pageUrl, options);
    // The lane opens again when the plugin's call really ends, even if we gave up waiting.
    unawaited(call.then<void>((_) {
      guard.cancel();
      free();
    }, onError: (Object _) {
      guard.cancel();
      free();
    }));
    final info = await call.timeout(Duration(seconds: _warm ? 20 : 45));
    _warm = true;
    debugPrint('[$videoId] $label: yt-dlp took ${sw.elapsedMilliseconds}ms');
    return info;
  }

  static String _describe(VideoFormat f) =>
      '${f.formatId ?? '?'} ${f.ext ?? '?'}${f.tbr == null ? '' : ' ${f.tbr}k'}';

  /// The headers yt-dlp says this link needs (YouTube ties a link to the client that asked
  /// for it, usually through the User-Agent). Empty if the plugin does not expose them.
  static Map<String, String> _headersOf(VideoFormat f) {
    try {
      final h = (f as dynamic).httpHeaders;
      if (h is Map) {
        return {
          for (final e in h.entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
        };
      }
    } catch (_) {}
    return const {};
  }

  /// Run after a googlevideo link failed: asks for the start of it in several ways and logs
  /// what each gets, so the log shows which kind of request YouTube accepts. Changes nothing.
  static Future<void> probe(String url) async {
    final clen = int.tryParse(Uri.parse(url).queryParameters['clen'] ?? '');
    final ranges = <String, String?>{
      '2 bytes': 'bytes=0-1',
      '256 KiB': 'bytes=0-262143',
      '1 MiB': 'bytes=0-1048575',
      '1.5 MiB': 'bytes=0-1572863',
      '2 MiB': 'bytes=0-2097151',
      // the end of the file: tells whether a range that reaches the last byte is the problem
      if (clen != null && clen > 204800)
        'last 100 KiB': 'bytes=${clen - 102400}-${clen - 1}',
      'open-ended': 'bytes=0-',
      'no range': null,
    };
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      for (final e in ranges.entries) {
        try {
          final req = await client.getUrl(Uri.parse(url));
          req.headers.removeAll(HttpHeaders.userAgentHeader);
          if (e.value != null) req.headers.set(HttpHeaders.rangeHeader, e.value!);
          final res = await req.close().timeout(const Duration(seconds: 8));
          // read the first piece only, the point is the status
          try {
            await res.first.timeout(const Duration(seconds: 4));
          } catch (_) {}
          debugPrint('probe [${e.key}]: HTTP ${res.statusCode}');
        } catch (err) {
          debugPrint('probe [${e.key}]: failed ${err.runtimeType}');
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  /// A playlist or manifest address (HLS / DASH), not a file that can be read directly.
  static bool _isPlaylist(String url) =>
      url.contains('/api/manifest/') || url.contains('.m3u8') || url.contains('.mpd');

  static VideoFormat? _pickFormat(VideoInfo info) {
    final formats = info.formats;
    if (formats == null) return null;
    VideoFormat? best; // audio-only, m4a first, then highest bitrate
    VideoFormat? fallback; // anything with audio
    VideoFormat? playlist; // an HLS / DASH playlist: only when there is nothing else
    for (final f in formats) {
      final url = f?.url ?? '';
      if (f == null || url.isEmpty) continue;
      if (f.acodec == null || f.acodec == 'none') continue;
      if (_isPlaylist(url)) {
        playlist ??= f;
        continue;
      }
      if (f.vcodec != 'none') {
        fallback ??= f;
        continue;
      }
      final b = best;
      final fM4a = f.ext == 'm4a';
      final bM4a = b?.ext == 'm4a';
      if (b == null ||
          (fM4a && !bM4a) ||
          (fM4a == bM4a && (f.tbr ?? 0) > (b.tbr ?? 0))) {
        best = f;
      }
    }
    return best ?? fallback ?? playlist;
  }
}
