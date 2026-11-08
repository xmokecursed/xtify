import 'dart:async';
import 'dart:io';
import 'package:extractor/extractor.dart';
import 'package:flutter/foundation.dart';
import '../services/cookie_service.dart';
import 'chunked_audio_source.dart' show linkProblem;
import 'connectivity_service.dart';
import 'cookie_refresh_service.dart';
import 'innertube_client.dart';
import '../utils/cache_util.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ResolvedAudioUrl {
  final String url;
  final Map<String, String> headers;
  final int? strategy;
  ResolvedAudioUrl({required this.url, required this.headers, this.strategy});
}

class _Strategy {
  final String label;
  final String? client;
  final bool cookies;
  final bool native;
  const _Strategy(this.label, this.client, this.cookies, {this.native = false});
}

class AudioUrlResolver {
  static final YoutubeDLFlutter _youtubeDL = YoutubeDLFlutter.instance;
  static final CacheUtil _cacheUtil = CacheUtil();
  static Future<void>? _initFuture;

  static const List<_Strategy> _strategies = [
    _Strategy('native', null, false, native: true),
    _Strategy('visionos', 'visionos', false),
    _Strategy('default', null, false),
    _Strategy('default+cookies', null, true),
    _Strategy('tv+cookies', 'tv', true),
    _Strategy('mweb+cookies', 'mweb', true),
  ];

  static const int nativeIndex = 0;

  static int preferredStrategy = 1;

  static bool canLookUpDirectly(String videoId) => InnertubeClient.canTry(videoId);

  static List<int> attemptOrder(String videoId) {
    final order = <int>[];
    if (canLookUpDirectly(videoId)) order.add(nativeIndex);
    for (var k = 0; k < _strategies.length; k++) {
      final i = (preferredStrategy + k) % _strategies.length;
      if (i != nativeIndex) order.add(i);
    }
    return order;
  }

  static bool _warm = false;

  static bool _running = false;
  static int _foregroundWaiting = 0;
  static int _runId = 0;
  static bool get isBusy => _running || _foregroundWaiting > 0;

  static DateTime _cookiesFirstUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static int get strategyCount => _strategies.length;
  static String strategyLabel(int i) => _strategies[i].label;

  static const String _prefKey = 'preferred_strategy_v5';

  static Future<void> loadPreferred() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_prefKey) ?? 1;
    if (v > nativeIndex && v < _strategies.length) preferredStrategy = v;
    unawaited(InnertubeClient.warmUp());
  }

  static Future<void> ensureInitialized() => _initFuture ??= _init();

  static Future<void> _init() async {
    final start = DateTime.now();
    final result = await _youtubeDL.initialize(enableFFmpeg: false);
    if (!result.success) {
      _initFuture = null;
      throw Exception('yt-dlp init failed: ${result.errorMessage}');
    }
    debugPrint('yt-dlp initialized in ${DateTime.now().difference(start).inMilliseconds}ms');
  }

  static const int _minYtDlp = 20260819;
  static const String _verKey = 'yt_dlp_version_v1';
  static const String _lastUpdateKey = 'yt_dlp_last_update';
  static Future<void>? _modernFuture;
  static bool _modernDone = false;
  static DateTime _modernRetryAt = DateTime.fromMillisecondsSinceEpoch(0);

  static int _dateOf(String? version) {
    final m = RegExp(r'(\d{4})\.(\d{1,2})\.(\d{1,2})').firstMatch(version ?? '');
    if (m == null) return 0;
    return int.parse(m[1]!) * 10000 + int.parse(m[2]!) * 100 + int.parse(m[3]!);
  }

  static Future<void> rememberVersion(String? version) async {
    if (_dateOf(version) == 0) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(_verKey, version!);
  }

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

  static Future<bool> _checkYtDlp() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_dateOf(prefs.getString(_verKey)) >= _minYtDlp) return true;
      final shown =
          (await _youtubeDL.getVersion().timeout(const Duration(seconds: 20))).youtubeDlVersion;
      debugPrint('yt-dlp inside the app: $shown');
      final have = _dateOf(shown);
      if (have == 0) return true;
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

  static ResolvedAudioUrl? cached(String videoId) {
    final item = _cacheUtil.get(videoId);
    if (item == null) return null;
    final url = item['url'] as String;
    return ResolvedAudioUrl(url: url, headers: const {});
  }

  static void markWorking(String videoId, int strategyIndex, ResolvedAudioUrl r) {
    final found = r.strategy ?? strategyIndex;
    if (found >= 0 && found < _strategies.length) {
      final s = _strategies[found];
      if (!s.cookies && !s.native) {
        preferredStrategy = found;
        SharedPreferences.getInstance().then((p) => p.setInt(_prefKey, found));
      }
    }
    _cacheUtil.put(videoId, {
      'url': r.url,
      'timestamp': 0,
      'expiresIn': _expirySeconds(r.url),
    });
  }

  static void clearCache(String videoId) => _cacheUtil.remove(videoId);

  static final Map<String, Future<ResolvedAudioUrl>> _inflight = {};
  static final Map<String, ResolvedAudioUrl> _prefetched = {};
  static final Map<String, DateTime> _prefetchedAt = {};
  static const Duration _prefetchLife = Duration(minutes: 20);

  static bool _ytDlpPrefetching = false;

  static void prefetch(String videoId, {bool ytDlpFallback = false}) {
    if (_prefetched.containsKey(videoId) || _inflight.containsKey(videoId)) return;
    if (cached(videoId) != null) return;
    final direct = canLookUpDirectly(videoId);
    if (!direct && (isBusy || _ytDlpPrefetching)) return;
    final Future<ResolvedAudioUrl> f;
    if (direct) {
      f = ytDlpFallback
          ? _directThenYtDlp(videoId)
          : AudioUrlResolver().resolve(videoId,
              strategyIndex: nativeIndex, background: true, checkWait: _prefetchCheckWait);
    } else {
      _ytDlpPrefetching = true;
      f = AudioUrlResolver().resolve(videoId,
          strategyIndex: preferredStrategy, background: true, checkWait: _prefetchCheckWait);
    }
    _inflight[videoId] = f;
    unawaited(f.then<void>((r) {
      _prefetched[videoId] = r;
      _prefetchedAt[videoId] = DateTime.now();
      _trimPrefetched();
    }, onError: (Object e) {
      debugPrint('prefetch failed for $videoId: $e');
    }).whenComplete(() {
      _inflight.remove(videoId);
      if (!direct) _ytDlpPrefetching = false;
    }));
  }

  static Future<ResolvedAudioUrl> _directThenYtDlp(String videoId) async {
    try {
      return await AudioUrlResolver().resolve(videoId,
          strategyIndex: nativeIndex, background: true, checkWait: _prefetchCheckWait);
    } catch (e) {
      if (isBusy || _ytDlpPrefetching) rethrow;
      debugPrint('[$videoId] prefetch: direct lookup failed ($e), trying yt-dlp');
      _ytDlpPrefetching = true;
      try {
        return await AudioUrlResolver().resolve(videoId,
            strategyIndex: preferredStrategy, background: true, checkWait: _prefetchCheckWait);
      } finally {
        _ytDlpPrefetching = false;
      }
    }
  }

  static void _trimPrefetched() {
    final now = DateTime.now();
    _prefetchedAt.removeWhere((id, at) {
      final old = now.difference(at) > _prefetchLife;
      if (old) _prefetched.remove(id);
      return old;
    });
    while (_prefetched.length > 40) {
      final id = _prefetched.keys.first;
      _prefetched.remove(id);
      _prefetchedAt.remove(id);
    }
  }

  static Future<ResolvedAudioUrl?> takePrefetched(String videoId) async {
    final inflight = _inflight[videoId];
    if (inflight != null) {
      try {
        final r = await inflight;
        _prefetched.remove(videoId);
        _prefetchedAt.remove(videoId);
        return r;
      } catch (_) {
        return null;
      }
    }
    final at = _prefetchedAt.remove(videoId);
    final r = _prefetched.remove(videoId);
    if (r == null) return null;
    if (at != null && DateTime.now().difference(at) > _prefetchLife) return null;
    return r;
  }

  static int _expirySeconds(String url) {
    final e = int.tryParse(Uri.tryParse(url)?.queryParameters['expire'] ?? '');
    if (e == null) return 1800;
    final left = e - DateTime.now().millisecondsSinceEpoch ~/ 1000 - 120;
    return left < 60 ? 60 : (left > 21600 ? 21600 : left);
  }

  Future<ResolvedAudioUrl> resolve(String videoId,
      {required int strategyIndex, bool background = false, Duration? checkWait}) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) {
      throw Exception('Invalid YouTube video ID');
    }
    final s = _strategies[strategyIndex];
    if (s.native) {
      return _resolveDirect(videoId, strategyIndex, wait: checkWait ?? _checkWait(background));
    }

    await ensureInitialized();
    await ensureModern().timeout(const Duration(seconds: 45),
        onTimeout: () => debugPrint('yt-dlp update is taking long, going on without it'));

    final options = <String, String>{
      '--socket-timeout': '10',
      '--extractor-retries': '1',
    };
    if (s.client != null) {
      options['--extractor-args'] = 'youtube:player_client=${s.client}';
    }
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
    final bad = await linkProblem(audioUrl,
        headers: headers,
        wait: checkWait ?? _checkWait(background),
        onLate: (why) => _foundBadLate(videoId, s.label, why));
    if (bad != null) {
      debugPrint('[$videoId] ${s.label}: link refused, $bad');
      throw Exception('YouTube refuses this link ($bad)');
    }
    return ResolvedAudioUrl(url: audioUrl, headers: headers, strategy: strategyIndex);
  }

  static Duration _checkWait(bool background) => Duration(seconds: background ? 6 : 2);

  static const Duration _prefetchCheckWait = Duration(seconds: 2);

  static void _foundBadLate(String videoId, String label, String why) {
    debugPrint('[$videoId] $label: link refused (found out late), $why');
    clearCache(videoId);
    _prefetched.remove(videoId);
    _prefetchedAt.remove(videoId);
  }

  static Future<ResolvedAudioUrl> _resolveDirect(String videoId, int strategyIndex,
      {required Duration wait}) async {
    final sw = Stopwatch()..start();
    final online = ConnectivityService.instance.online.value;
    final found = await InnertubeClient.audioFor(videoId, countFailures: online);
    final lookupMs = sw.elapsedMilliseconds;
    final bad = await linkProblem(found.url,
        headers: const {},
        wait: wait,
        onLate: (why) {
          _foundBadLate(videoId, 'native', why);
          if (online) InnertubeClient.noteBadLink(why);
        });
    if (bad != null) {
      debugPrint('[$videoId] native: link refused, $bad');
      if (online) InnertubeClient.noteBadLink(bad);
      throw Exception('YouTube refuses this link ($bad)');
    }
    debugPrint('[$videoId] native: audio url from ${Uri.tryParse(found.url)?.host ?? '?'} '
        '(${found.description}) took ${lookupMs}ms + ${sw.elapsedMilliseconds - lookupMs}ms link check');
    return ResolvedAudioUrl(url: found.url, headers: const {}, strategy: strategyIndex);
  }

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

    final guard = Timer(const Duration(seconds: 90), free);
    final waited = queued.elapsedMilliseconds;
    debugPrint('[$videoId] $label: yt-dlp start'
        '${waited > 300 ? ' (waited ${waited}ms for another lookup)' : ''}');
    final sw = Stopwatch()..start();
    final call = _youtubeDL.getVideoInfoWithOptions(pageUrl, options);
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

  static Future<void> probe(String url) async {
    final clen = int.tryParse(Uri.parse(url).queryParameters['clen'] ?? '');
    final ranges = <String, String?>{
      '2 bytes': 'bytes=0-1',
      '256 KiB': 'bytes=0-262143',
      '1 MiB': 'bytes=0-1048575',
      '1.5 MiB': 'bytes=0-1572863',
      '2 MiB': 'bytes=0-2097151',
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
          try {
            await res.first.timeout(const Duration(seconds: 4));
          } catch (_) {}
          debugPrint('probe [${e.key}]: HTTP ${res.statusCode}');
        } catch (err) {
          debugPrint('probe [${e.key}]: failed ${err.runtimeType}');
          if (err is SocketException || err is TimeoutException) break;
        }
      }
    } finally {
      client.close(force: true);
    }
  }

  static bool _isPlaylist(String url) =>
      url.contains('/api/manifest/') || url.contains('.m3u8') || url.contains('.mpd');

  static VideoFormat? _pickFormat(VideoInfo info) {
    final formats = info.formats;
    if (formats == null) return null;
    VideoFormat? best;
    VideoFormat? fallback;
    VideoFormat? playlist;
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
