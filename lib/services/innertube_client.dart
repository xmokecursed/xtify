import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'hedged.dart';

/// One audio stream of a video, found by [InnertubeClient].
class InnertubeAudio {
  final String url;
  final String description; // for the log, e.g. "140 audio/mp4 129k"
  const InnertubeAudio({required this.url, required this.description});
}

/// The direct lookup failed. [videoSpecific] means YouTube says something about THIS video
/// (private, age restricted, ...) rather than about the lookup itself. [botCheck] means it took
/// the visitor for a bot ("Sign in to confirm you're not a bot").
class InnertubeException implements Exception {
  final String message;
  final bool videoSpecific;
  final bool botCheck;
  const InnertubeException(this.message, {this.videoSpecific = false, this.botCheck = false});

  @override
  String toString() => message;
}

/// What YouTube gets to recognise a visitor by: the id and the cookies a page load hands out.
class _Session {
  final String visitorData;
  final Map<String, String> cookies;
  final String page; // the video whose watch page this was made from
  final DateTime _made = DateTime.now();
  _Session(this.visitorData, this.cookies, this.page);

  Duration get age => DateTime.now().difference(_made);

  String get cookieHeader => cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

/// Asks YouTube's own player API for a song's audio link: one request, no yt-dlp.
///
/// yt-dlp costs 6-8 seconds a song on a phone, nearly all of it Python starting up again for
/// every lookup; the request itself is a few hundred milliseconds. This sends the same request
/// yt-dlp's "visionos" client does (it is the client yt-dlp uses where there is no JavaScript
/// runtime, needs no PO token and no player script, and its links play to the end), and reads
/// the answer the way yt-dlp does. Several lookups can run at once, since nothing here is
/// shared with yt-dlp's one-at-a-time lane.
///
/// What it must also do is what yt-dlp does first: load a YouTube page once, keep the visitor
/// id and the cookies that come with it, and send them along with every request. A request
/// from a visitor YouTube has never seen is answered with "Sign in to confirm you're not a
/// bot" (that is what the first version of this got on a phone where yt-dlp worked).
///
/// It is the fast path, not the only one: when it fails the resolver falls back to yt-dlp, and
/// after repeated failures it is switched off for a while ([healthy]) so a changed API costs
/// nothing but a few seconds, once.
class InnertubeClient {
  InnertubeClient._();

  // Copied from yt-dlp's INNERTUBE_CLIENTS['visionos'].
  static const String _clientName = 'VISIONOS';
  static const String _clientNameId = '101';
  static const String _clientVersion = '1.02';
  static const String _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Version/26.0 Safari/605.1.15';
  static final Uri _endpoint =
      Uri.parse('https://www.youtube.com/youtubei/v1/player?prettyPrint=false');

  // What yt-dlp adds to every request it makes (its std_headers), and the browser it loads the
  // watch page as.
  static const String _accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
  static const String _acceptLanguage = 'en-us,en;q=0.5';
  static const String _pageUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/149.0.0.0 Safari/537.36';

  // One client for all lookups, so the connection to YouTube stays open between them.
  static HttpClient? _httpClient;
  static HttpClient get _http => _httpClient ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 60);

  // ---------------- session ----------------

  static const Duration _sessionLife = Duration(hours: 2);
  // a page to start the session from when no song is at hand ("Me at the zoo")
  static const String _warmUpVideo = 'jNQXAC9IVRw';
  // the visitor id sits in the first lines of the page's config; this is only a safety stop
  static const int _pageLimit = 2 * 1024 * 1024;
  static final RegExp _visitorRe = RegExp(r'"(?:VISITOR_DATA|visitorData)"\s*:\s*"([^"\\]+)"');

  static _Session? _session;
  static Future<_Session>? _starting;

  /// Starts the session ahead of the first song, so the first lookup does not wait for it.
  /// Never throws.
  static Future<void> warmUp() async {
    try {
      await _sessionFor();
    } catch (e) {
      debugPrint('direct lookup: could not start a session ahead of time: $e');
    }
  }

  static Future<_Session> _sessionFor({String? videoId}) async {
    final s = _session;
    if (s != null && s.age < _sessionLife) return s;
    final running = _starting;
    if (running != null) return running;
    final started = _startSession(videoId);
    _starting = started;
    try {
      final made = await started;
      _session = made;
      return made;
    } finally {
      if (identical(_starting, started)) _starting = null;
    }
  }

  static void _dropSession(_Session s) {
    if (identical(_session, s)) _session = null;
  }

  static Future<_Session> _startSession(String? videoId) async {
    final id = (videoId != null && RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId))
        ? videoId
        : _warmUpVideo;
    try {
      // a page load that has not answered after 3 s is asked for again on a new connection
      // (the one kept open from earlier may be dead)
      return await hedged<_Session>(
        () => _loadPage(id),
        after: const Duration(seconds: 3),
        tries: 2,
        limit: const Duration(seconds: 10),
        fatal: (e) => e is InnertubeException,
      );
    } on TimeoutException {
      throw const InnertubeException('YouTube page: no answer in 10s');
    }
  }

  /// Loads the watch page the way yt-dlp does and takes the visitor id and the cookies from it.
  static Future<_Session> _loadPage(String id) async {
    final sw = Stopwatch()..start();
    // yt-dlp starts every run with these two (language and "cookies accepted")
    final jar = <String, String>{'PREF': 'hl=en&tz=UTC', 'SOCS': 'CAI'};
    final req = await _http
        .getUrl(Uri.parse('https://www.youtube.com/watch?v=$id&bpctr=9999999999&has_verified=1'));
    req.headers
      ..set(HttpHeaders.userAgentHeader, _pageUserAgent)
      ..set(HttpHeaders.acceptHeader, _accept)
      ..set(HttpHeaders.acceptLanguageHeader, _acceptLanguage)
      ..set('Sec-Fetch-Mode', 'navigate')
      ..set(HttpHeaders.cookieHeader, jar.entries.map((e) => '${e.key}=${e.value}').join('; '));
    final res = await req.close();
    if (res.statusCode != 200) {
      final what = await _peek(res);
      throw InnertubeException(
          'YouTube page got HTTP ${res.statusCode}${what.isEmpty ? '' : ': $what'}');
    }
    _takeCookies(res, jar);

    String? visitor;
    var carry = '';
    var seen = 0;
    await for (final chunk in res.transform(const Utf8Decoder(allowMalformed: true))) {
      final text = carry + chunk;
      visitor = _visitorRe.firstMatch(text)?.group(1);
      // leaving the loop drops the rest of the page (the connection is closed)
      if (visitor != null) break;
      seen += chunk.length;
      if (seen > _pageLimit) break;
      carry = text.length > 600 ? text.substring(text.length - 600) : text;
    }
    if (visitor == null) throw const InnertubeException('YouTube page had no visitor id');
    debugPrint('direct lookup: session started in ${sw.elapsedMilliseconds}ms '
        '(visitor id, cookies: ${jar.keys.join(', ')})');
    return _Session(visitor, jar, id);
  }

  /// Keeps the cookies a response sets, the way a browser's cookie jar would.
  static void _takeCookies(HttpClientResponse res, Map<String, String> jar) {
    final lines = res.headers[HttpHeaders.setCookieHeader];
    if (lines == null) return;
    for (final line in lines) {
      final parts = line.split(';');
      final pair = parts.first;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      var gone = value.isEmpty;
      for (final attr in parts.skip(1)) {
        final a = attr.trim().toLowerCase();
        if (a == 'max-age=0' || a.startsWith('max-age=-')) gone = true;
        if (a.startsWith('expires=') && a.contains('1970')) gone = true;
      }
      if (gone) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
  }

  /// The start of an error page, for the log. Never throws.
  static Future<String> _peek(HttpClientResponse res) async {
    try {
      final text = await res
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(const Duration(seconds: 3));
      final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return one.length > 160 ? one.substring(0, 160) : one;
    } catch (_) {
      return '';
    }
  }

  // ---------------- health ----------------

  static const int _threshold = 3; // failures in a row before it is switched off
  static int _failures = 0;
  static int _backoffMin = 10;
  static DateTime _openUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// False while the direct lookup is switched off after repeated failures.
  static bool get healthy => !DateTime.now().isBefore(_openUntil);

  // Videos YouTube will not give out to this client (made for kids, age restricted, ...):
  // go straight to yt-dlp for those for a while.
  static final Map<String, DateTime> _skipUntil = {};

  static bool _skip(String videoId) {
    final t = _skipUntil[videoId];
    if (t == null) return false;
    if (DateTime.now().isAfter(t)) {
      _skipUntil.remove(videoId);
      return false;
    }
    return true;
  }

  /// Whether it is worth trying the direct lookup for [videoId] now.
  static bool canTry(String videoId) => healthy && !_skip(videoId);

  static void _succeeded() {
    _failures = 0;
    _backoffMin = 10;
  }

  static void _failed(String why) {
    if (!healthy) return; // already off; late answers of lookups that were in flight
    _failures++;
    if (_failures < _threshold) return;
    debugPrint('direct lookup: switched off for $_backoffMin min after repeated failures '
        '(last: $why), yt-dlp takes over');
    _openUntil = DateTime.now().add(Duration(minutes: _backoffMin));
    // when it comes back, one more failure switches it off again at once, for longer
    _failures = _threshold - 1;
    _backoffMin = _backoffMin * 2 > 60 ? 60 : _backoffMin * 2;
  }

  /// For the caller to report a link from here that YouTube then refused.
  static void noteBadLink(String why) => _failed('link refused: $why');

  // ---------------- the lookup ----------------

  /// The best audio link for [videoId]. Throws [InnertubeException] (never a
  /// TimeoutException) so the caller can simply go on to the next way of finding one.
  /// With [countFailures] false (the phone is offline) a failure says nothing about the lookup.
  static Future<InnertubeAudio> audioFor(
    String videoId, {
    Duration timeout = const Duration(seconds: 6),
    bool countFailures = true,
  }) async {
    try {
      final audio = await _lookup(videoId).timeout(timeout);
      _succeeded();
      return audio;
    } on InnertubeException catch (e) {
      if (e.videoSpecific) {
        if (_skipUntil.length > 200) _skipUntil.clear();
        _skipUntil[videoId] = DateTime.now().add(const Duration(minutes: 15));
      } else if (countFailures) {
        _failed(e.message);
      }
      rethrow;
    } on TimeoutException {
      if (countFailures) _failed('no answer in ${timeout.inSeconds}s');
      throw InnertubeException('direct lookup: no answer in ${timeout.inSeconds}s');
    } catch (e) {
      if (countFailures) _failed('${e.runtimeType}');
      throw InnertubeException('direct lookup failed (${e.runtimeType})');
    }
  }

  // After a lookup was refused with the shared session but went through with a session made
  // on the song's own page (what yt-dlp does for every song), every lookup starts from the
  // song's own page until this time.
  static DateTime _pagePerSongUntil = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<InnertubeAudio> _lookup(String videoId) async {
    final perSong = DateTime.now().isBefore(_pagePerSongUntil);
    var session = perSong ? await _startSession(videoId) : await _sessionFor(videoId: videoId);
    var retried = false;
    var wasYoung = false;
    while (true) {
      try {
        final answer = await _ask(videoId, session);
        final audio = _read(answer, videoId);
        if (retried) {
          if (wasYoung) {
            // refused on another song's page, fine on its own: do it that way for a while
            _pagePerSongUntil = DateTime.now().add(const Duration(minutes: 30));
            debugPrint('direct lookup: works with the song\'s own page, '
                'loading one per song for a while');
          } else {
            _session = session; // the new one takes the place of the one that had gone stale
          }
        }
        return audio;
      } on InnertubeException catch (e) {
        if (!e.botCheck) rethrow;
        // YouTube takes this visitor for a bot. The session may be to blame: it may have
        // gone stale (the phone changed networks, say), or it was made on another song's
        // page. One made right now on this song's own page is the best there is: try that
        // once. If even that is refused, that is the answer.
        final best = session.page == videoId && session.age < const Duration(minutes: 1);
        _dropSession(session);
        if (retried || best) rethrow;
        retried = true;
        wasYoung = session.age < const Duration(minutes: 1);
        debugPrint('direct lookup: refused as a bot with a session that is '
            '${session.age.inSeconds}s old, trying a new one made on this song\'s page');
        session = await _startSession(videoId);
      }
    }
  }

  /// The player request. When it has not been answered after two and a half seconds it is asked
  /// again on a new connection: the connection kept open between lookups may have been dropped
  /// by the phone's network without anyone being told, and waiting for it to give up would cost
  /// the lookup its whole six seconds (and count as a failure of the direct lookup).
  static Future<Map<String, dynamic>> _ask(String videoId, _Session session) {
    return hedged<Map<String, dynamic>>(
      () => _askOnce(videoId, session),
      after: const Duration(milliseconds: 2500),
      tries: 2,
      limit: const Duration(seconds: 8),
      // what the server answered (an HTTP error) is not made better by asking again
      fatal: (e) => e is InnertubeException,
      onExtra: (n) => debugPrint('direct lookup: no answer after 2.5 s, asking again on a new connection'),
    );
  }

  static Future<Map<String, dynamic>> _askOnce(String videoId, _Session session) async {
    final body = utf8.encode(jsonEncode(<String, Object?>{
      'context': <String, Object?>{
        'client': <String, Object?>{
          'clientName': _clientName,
          'clientVersion': _clientVersion,
          'deviceMake': 'Apple',
          'deviceModel': 'RealityDevice17,1',
          'userAgent': _userAgent,
          'osName': 'visionOS',
          'osVersion': '26.5.23O471',
          'hl': 'en',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
        },
      },
      'videoId': videoId,
      'playbackContext': <String, Object?>{
        'contentPlaybackContext': <String, Object?>{'html5Preference': 'HTML5_PREF_WANTS'},
      },
      'contentCheckOk': true,
      'racyCheckOk': true,
    }));
    final req = await _http.postUrl(_endpoint);
    req.headers
      ..set('X-YouTube-Client-Name', _clientNameId)
      ..set('X-YouTube-Client-Version', _clientVersion)
      ..set('Origin', 'https://www.youtube.com')
      ..set('X-Goog-Visitor-Id', session.visitorData)
      ..set(HttpHeaders.cookieHeader, session.cookieHeader)
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.acceptHeader, _accept)
      ..set(HttpHeaders.acceptLanguageHeader, _acceptLanguage)
      ..set('Sec-Fetch-Mode', 'navigate');
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    _takeCookies(res, session.cookies);
    if (res.statusCode != 200) {
      final what = await _peek(res);
      throw InnertubeException(
          'player request got HTTP ${res.statusCode}${what.isEmpty ? '' : ': $what'}');
    }
    final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const InnertubeException('player answer is not what was expected');
    }
    return decoded;
  }

  // ---------------- reading the answer ----------------

  static Map<String, dynamic>? _asMap(Object? v) => v is Map<String, dynamic> ? v : null;

  static int? _int(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
  }

  static InnertubeAudio _read(Map<String, dynamic> answer, String videoId) {
    final status = _asMap(answer['playabilityStatus']);
    final state = status?['status'];
    if (state != 'OK') {
      final reasonRaw = status?['reason'];
      final reason = reasonRaw is String ? reasonRaw : '';
      // "Sign in to confirm you're not a bot" is about the visitor, not about the video
      final bot = reason.toLowerCase().contains('bot');
      throw InnertubeException(
        'YouTube says ${state ?? 'nothing'}${reason.isEmpty ? '' : ': $reason'}',
        videoSpecific: !bot,
        botCheck: bot,
      );
    }

    final details = _asMap(answer['videoDetails']);
    if (details?['videoId'] != videoId) {
      // what YouTube does with a client it no longer serves: answers for another video
      throw const InnertubeException('YouTube answered for another video');
    }
    final seconds = _int(details?['lengthSeconds']);

    final formats = _asMap(answer['streamingData'])?['adaptiveFormats'];
    if (formats is! List || formats.isEmpty) {
      throw const InnertubeException('no streams in the answer');
    }

    // Same choice yt-dlp makes (audio track, then not the "DRC" one), then m4a before webm
    // (it can be tagged after a download), then the highest bitrate.
    Map<String, dynamic>? best;
    var bestKey = const <int>[];
    for (final item in formats) {
      final f = _asMap(item);
      if (f == null) continue;
      final mime = f['mimeType'];
      if (mime is! String || !mime.startsWith('audio/')) continue;
      final url = f['url'];
      // a link that comes as a signed cipher needs the player script, which a phone has no
      // JavaScript runtime to run
      if (url is! String || url.isEmpty) continue;
      if (f['drmFamilies'] != null) continue;
      if (f['targetDurationSec'] != null) continue; // live
      if (f['type'] == 'FORMAT_STREAM_TYPE_OTF') continue;
      // an "n" value in the link has to be solved by that same script, or it is throttled
      if (RegExp(r'[?&]n=').hasMatch(url)) continue;
      final ms = _int(f['approxDurationMs']);
      if (seconds != null && ms != null && ms / 1000 < seconds / 2) continue; // damaged

      final track = _asMap(f['audioTrack']);
      final trackName = ((track?['displayName'] as String?) ?? '').toLowerCase();
      final language = trackName.contains('descriptive')
          ? -10
          : trackName.contains('original')
              ? 10
              : track?['audioIsDefault'] == true
                  ? 5
                  : -1;
      final key = <int>[
        language,
        f['isDrc'] == true ? 0 : 1,
        mime.startsWith('audio/mp4') ? 1 : 0,
        _int(f['averageBitrate']) ?? _int(f['bitrate']) ?? 0,
      ];
      if (best == null || _compare(key, bestKey) > 0) {
        best = f;
        bestKey = key;
      }
    }
    if (best == null) throw const InnertubeException('no playable audio stream in the answer');
    final url = best['url'] as String;
    final kbps = (bestKey[3] / 1000).round();
    return InnertubeAudio(
      url: url,
      description: '${best['itag'] ?? '?'} ${(best['mimeType'] as String).split(';').first} ${kbps}k',
    );
  }
}
