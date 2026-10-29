import 'dart:io';
import 'package:extractor/extractor.dart';
import 'package:flutter/foundation.dart';
import '../services/cookie_service.dart';
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
    // Clients that hand out direct audio links need no YouTube player script solved, so
    // they are the quick ones on a phone. The default client has to run that script,
    // which is slow without a JavaScript runtime, so it goes after them.
    _Strategy('android_vr', 'android_vr', false),
    _Strategy('ios', 'ios', false),
    _Strategy('default', null, false),
    _Strategy('default+cookies', null, true),
    _Strategy('tv+cookies', 'tv', true),
    _Strategy('mweb+cookies', 'mweb', true),
  ];

  static int preferredStrategy = 0;
  // The first run pays for loading yt-dlp, later ones should be quick: a stuck attempt
  // is cut off after 12 s so the next strategy starts (it used to wait 40 s every time).
  static bool _warm = false;
  // yt-dlp runs on the phone's CPU: two runs at once make each far slower.
  static int _active = 0;
  static bool get isBusy => _active > 0;

  // After a block is detected, go straight to cookies for a while.
  static DateTime _cookiesFirstUntil = DateTime.fromMillisecondsSinceEpoch(0);
  static int get strategyCount => _strategies.length;
  static String strategyLabel(int i) => _strategies[i].label;

  static const String _prefKey = 'preferred_strategy_v3';

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

  static ResolvedAudioUrl? cached(String videoId) {
    final item = _cacheUtil.get(videoId);
    if (item == null) return null;
    final url = item['url'] as String;
    return ResolvedAudioUrl(url: url, headers: const {});
  }

  /// Call only after the URL actually played.
  static void markWorking(String videoId, int strategyIndex, ResolvedAudioUrl r) {
    preferredStrategy = strategyIndex;
    SharedPreferences.getInstance().then((p) => p.setInt(_prefKey, strategyIndex));
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
    final f = AudioUrlResolver().resolve(videoId, strategyIndex: preferredStrategy);
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

  Future<ResolvedAudioUrl> resolve(String videoId, {required int strategyIndex}) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) {
      throw Exception('Invalid YouTube video ID');
    }
    await ensureInitialized();

    final s = _strategies[strategyIndex];
    final options = <String, String>{
      // fail fast on a dead connection instead of waiting on yt-dlp's long defaults
      '--socket-timeout': '10',
      '--extractor-retries': '1',
    };
    if (s.client != null) {
      options['--extractor-args'] = 'youtube:player_client=${s.client}';
    }
    // The default client can use cookies during a block window; the
    // android_vr / ios clients are left alone.
    final cookiesFirst =
        s.client == null && DateTime.now().isBefore(_cookiesFirstUntil);
    if (s.cookies || cookiesFirst) {
      final f = await CookieService.instance.cookieFile();
      if (f == null && s.cookies) throw Exception('not signed in (no cookie file)');
      if (f != null) options['--cookies'] = f.path;
    }
    Future<VideoInfo> fetch(Map<String, String> o) async {
      debugPrint('[$videoId] yt-dlp start, $_active already running');
      _active++;
      try {
        return await _youtubeDL
            .getVideoInfoWithOptions('https://www.youtube.com/watch?v=$videoId', o)
            .timeout(Duration(seconds: _warm ? 12 : 40));
      } finally {
        _active--;
      }
    }
    final sw = Stopwatch()..start();
    VideoInfo info;
    try {
      info = await fetch(options);
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
      info = await fetch({...options, '--cookies': f.path});
    }
    _warm = true;
    debugPrint('[$videoId] ${s.label}: yt-dlp took ${sw.elapsedMilliseconds}ms');

    final format = _pickFormat(info);
    final audioUrl = format?.url;
    if (format == null || audioUrl == null) throw Exception('no audio format returned');
    debugPrint('[$videoId] ${s.label}: audio url from ${Uri.parse(audioUrl).host}');
    return ResolvedAudioUrl(url: audioUrl, headers: _headersOf(format));
  }

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
    const ranges = <String, String?>{
      '2 bytes': 'bytes=0-1',
      'open-ended': 'bytes=0-',
      '1 MiB': 'bytes=0-1048575',
      '10 MiB': 'bytes=0-10485759',
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

  static VideoFormat? _pickFormat(VideoInfo info) {
    final formats = info.formats;
    if (formats == null) return null;
    VideoFormat? best; // audio-only, m4a first, then highest bitrate
    VideoFormat? fallback; // anything with audio
    for (final f in formats) {
      if (f == null || (f.url ?? '').isEmpty) continue;
      if (f.acodec == null || f.acodec == 'none') continue;
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
    return best ?? fallback;
  }
}
