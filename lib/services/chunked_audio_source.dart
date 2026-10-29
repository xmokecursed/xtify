import 'dart:io';
import 'dart:math' show max, min;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

const String _fallbackUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/141.0.0.0 Safari/537.36';

final HttpClient _http = HttpClient()
  ..autoUncompress = false
  ..connectionTimeout = const Duration(seconds: 10)
  ..idleTimeout = const Duration(seconds: 30);

/// A direct media link on googlevideo (not a playlist or manifest).
bool _isDirectMedia(Uri uri) =>
    uri.host.endsWith('googlevideo.com') && uri.path.contains('videoplayback');

/// What the player is given for a resolved link. A direct googlevideo link is read in bounded
/// pieces ([ChunkedHttpAudioSource]); any other link goes straight to the player.
AudioSource audioSourceFor(String url, {Map<String, String>? headers, dynamic tag}) {
  final uri = Uri.parse(url);
  if (_isDirectMedia(uri)) {
    return ChunkedHttpAudioSource(uri, headers: headers ?? const {}, tag: tag);
  }
  return AudioSource.uri(
    uri,
    headers: (headers == null || headers.isEmpty) ? null : headers,
    tag: tag,
  );
}

/// One bounded request for bytes [from] to [toInclusive] of [uri]. The answer is not read here.
Future<HttpClientResponse> _rangeRequest(
    Uri uri, Map<String, String> headers, int from, int toInclusive) async {
  final req = await _http.getUrl(uri);
  headers.forEach((k, v) => req.headers.set(k, v));
  if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
    req.headers.set(HttpHeaders.userAgentHeader, _fallbackUserAgent);
  }
  req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$toInclusive');
  return req.close().timeout(const Duration(seconds: 15));
}

/// Asks for two bytes from the middle of the file, the way the player will, and says what is
/// wrong with the link: null when it works, or when the check could not be made.
///
/// YouTube cuts some links off after about 1 MiB (a minute of audio) and refuses others
/// outright. Asking past the first MiB shows that now, instead of a minute into the song.
Future<String?> linkProblem(String url, {Map<String, String> headers = const {}}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !_isDirectMedia(uri)) return null;
  final clen = int.tryParse(uri.queryParameters['clen'] ?? '');
  // past the first MiB, where the cut-off links stop working; near the end of a short file
  final at = clen == null ? 0 : max(0, min(clen - 2, max(1310720, clen ~/ 2)));
  final what = 'bytes=$at-${at + 1}';
  final sw = Stopwatch()..start();
  try {
    final res = await _rangeRequest(uri, headers, at, at + 1);
    final code = res.statusCode;
    try {
      if (code == 206 || code >= 400) {
        // a tiny body: read it so the connection can be used again by the player
        await res.drain<void>().timeout(const Duration(seconds: 3));
      } else {
        // the server ignored the range and is sending the whole file: stop it
        await res.first.timeout(const Duration(seconds: 3));
      }
    } catch (_) {}
    if (code == 200 || code == 206) {
      debugPrint('link works: HTTP $code for $what, took ${sw.elapsedMilliseconds}ms');
      return null;
    }
    // 429 (slow down) and 416 (a size that does not match) say nothing about the link itself
    if (code >= 400 && code < 500 && code != 429 && code != 416) return 'HTTP $code for $what';
    debugPrint('link check skipped: HTTP $code for $what');
    return null;
  } catch (e) {
    debugPrint('link check skipped (${e.runtimeType})');
    return null;
  }
}

class _Piece {
  final HttpClientResponse res;
  final int to; // exclusive end of the range that was asked for
  _Piece(this.res, this.to);
}

class _Refused implements Exception {
  final int status;
  final String what;
  _Refused(this.status, this.what);
  @override
  String toString() => 'YouTube answered $status for $what';
}

/// Plays a YouTube (googlevideo) link by asking for it in bounded pieces.
///
/// These links answer 403 to a request with no Range header and to an open-ended one
/// ("bytes=0-"). The player always starts a song with no Range header, so it cannot open the
/// link by itself. This source sits between: the player asks it for a range, it fetches that
/// range from YouTube in bounded pieces and hands the bytes over. Seeking works because the
/// player's own range is passed on.
class ChunkedHttpAudioSource extends StreamAudioSource {
  ChunkedHttpAudioSource(this.uri, {Map<String, String> headers = const {}, super.tag})
      : headers = {
          for (final e in headers.entries)
            if (e.key.toLowerCase() != 'range') e.key: e.value,
        };

  final Uri uri;
  final Map<String, String> headers;

  // yt-dlp itself downloads these links in pieces of 10 MiB, so 4 MiB is safe. If a piece is
  // refused with 403, half of it is tried; the smaller size is kept for this song only when
  // the smaller request works (a refusal that has nothing to do with the size never shrinks it).
  int _size = 4 * 1024 * 1024;
  static const int _minSize = 256 * 1024;

  int? _total;

  String get _type {
    final m = uri.queryParameters['mime']; // e.g. audio/mp4 or audio/webm
    return (m != null && m.contains('/')) ? m : 'audio/mp4';
  }

  /// One bounded request for bytes [from] to [toInclusive].
  Future<HttpClientResponse> _open(int from, int toInclusive) async {
    final what = 'bytes=$from-$toInclusive';
    for (var attempt = 0;; attempt++) {
      try {
        final res = await _rangeRequest(uri, headers, from, toInclusive);
        if (res.statusCode == 206 || (res.statusCode == 200 && from == 0)) return res;
        final status = res.statusCode;
        try {
          await res.drain<void>().timeout(const Duration(seconds: 2));
        } catch (_) {}
        throw _Refused(status, what);
      } on _Refused {
        rethrow;
      } catch (e) {
        // a dropped connection or a slow answer: one more try, then give up
        if (attempt >= 1) {
          debugPrint('chunked source: $what failed ($e)');
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  /// Asks for the next piece, at most [_size] bytes from [from] and never past [limit]
  /// (exclusive, null when the length is unknown). A 403 halves the piece and asks again.
  Future<_Piece> _openPiece(int from, int? limit) async {
    var size = _size;
    while (true) {
      final to = limit == null ? from + size : min(from + size, limit);
      try {
        final piece = _Piece(await _open(from, to - 1), to);
        if (size < _size) {
          _size = size; // the smaller request worked where the bigger one was refused
          debugPrint('chunked source: pieces are now ${size ~/ 1024} KiB');
        }
        return piece;
      } on _Refused catch (e) {
        final span = to - from;
        if (e.status != 403 || span <= _minSize) {
          debugPrint('chunked source: failed, $e');
          rethrow;
        }
        size = max(_minSize, span ~/ 2);
        debugPrint('chunked source: 403 for $span bytes, trying ${size ~/ 1024} KiB');
      }
    }
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final sw = Stopwatch()..start();
    final from = start ?? 0;
    final known = _total ?? int.tryParse(uri.queryParameters['clen'] ?? '');
    final wantEnd = end ?? known; // exclusive; null while the length is unknown
    final piece = await _openPiece(from, wantEnd);
    final first = piece.res;

    var total = known;
    if (first.statusCode == 200) {
      // the server ignored the range and sends everything
      if (first.contentLength >= 0) total = first.contentLength;
    } else {
      final range = first.headers.value(HttpHeaders.contentRangeHeader) ?? '';
      final m = RegExp(r'/(\d+)\s*$').firstMatch(range);
      if (m != null) total = int.parse(m[1]!);
    }
    _total = total;
    final stopAt = end ?? total; // exclusive end of what the player wants
    debugPrint('chunked source: bytes $from-${stopAt ?? ''} took '
        '${sw.elapsedMilliseconds}ms (HTTP ${first.statusCode})');
    return StreamAudioResponse(
      rangeRequestsSupported: true,
      sourceLength: total,
      contentLength: stopAt == null ? null : stopAt - from,
      offset: from,
      stream: _pieces(first, from, piece.to, stopAt),
      contentType: _type,
    );
  }

  /// The bytes of [first], then of as many further bounded requests as it takes to reach
  /// [stopAt] (or the end of the file when its length is unknown).
  Stream<List<int>> _pieces(HttpClientResponse first, int from, int firstEnd, int? stopAt) async* {
    var pos = from;
    var res = first;
    var asked = firstEnd; // exclusive end of what the current request asked for
    while (true) {
      var got = 0;
      await for (final data in res.timeout(const Duration(seconds: 20))) {
        got += data.length;
        pos += data.length;
        yield data;
      }
      if (res.statusCode == 200) return; // everything arrived in one go
      if (got == 0) return; // nothing came back: stop instead of asking forever
      if (stopAt != null && pos >= stopAt) return;
      if (stopAt == null && pos < asked) return; // shorter than asked for: that was the end
      final next = await _openPiece(pos, stopAt);
      res = next.res;
      asked = next.to;
    }
  }
}
