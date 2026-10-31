import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One audio stream of a video, found by [InnertubeClient].
class InnertubeAudio {
  final String url;
  final String description; // for the log, e.g. "140 audio/mp4 129k"
  const InnertubeAudio({required this.url, required this.description});
}

/// The direct lookup failed. [videoSpecific] means YouTube says something about THIS video
/// (private, age restricted, ...) rather than about the lookup itself.
class InnertubeException implements Exception {
  final String message;
  final bool videoSpecific;
  const InnertubeException(this.message, {this.videoSpecific = false});

  @override
  String toString() => message;
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

  // One client for all lookups, so the connection to YouTube stays open between them.
  static HttpClient? _httpClient;
  static HttpClient get _http => _httpClient ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 60);

  // ---------------- visitor id ----------------

  // YouTube hands out an id with every answer; sending it back on the next request is what a
  // browser does. Kept between runs.
  static const String _visitorKey = 'innertube_visitor_v1';
  static String? _visitorData;

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      _visitorData = p.getString(_visitorKey);
    } catch (_) {}
  }

  static void _rememberVisitor(String? v) {
    if (v == null || v.isEmpty || v == _visitorData) return;
    _visitorData = v;
    unawaited(SharedPreferences.getInstance().then<void>((p) async {
      await p.setString(_visitorKey, v);
    }, onError: (Object _) {}));
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
      final answer = await _ask(videoId).timeout(timeout);
      final audio = _read(answer, videoId);
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

  static Future<Map<String, dynamic>> _ask(String videoId) async {
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
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    final visitor = _visitorData;
    if (visitor != null) req.headers.set('X-Goog-Visitor-Id', visitor);
    req.contentLength = body.length;
    req.add(body);
    final res = await req.close();
    if (res.statusCode != 200) {
      try {
        await res.drain<void>();
      } catch (_) {}
      throw InnertubeException('player request got HTTP ${res.statusCode}');
    }
    final text = await res.transform(utf8.decoder).join();
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
    _rememberVisitor(_asMap(answer['responseContext'])?['visitorData'] as String?);

    final status = _asMap(answer['playabilityStatus']);
    final state = status?['status'];
    if (state != 'OK') {
      final reasonRaw = status?['reason'];
      final reason = reasonRaw is String ? reasonRaw : '';
      // "Sign in to confirm you're not a bot" is about the connection, not about the video
      final bot = reason.toLowerCase().contains('bot');
      if (bot) _visitorData = null; // start again with a fresh id
      throw InnertubeException(
        'YouTube says ${state ?? 'nothing'}${reason.isEmpty ? '' : ': $reason'}',
        videoSpecific: !bot,
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
