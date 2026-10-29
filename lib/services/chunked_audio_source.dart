import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// What the player is given for a resolved link. A googlevideo link is read in bounded
/// pieces ([ChunkedHttpAudioSource]); any other link goes straight to the player.
AudioSource audioSourceFor(String url, {Map<String, String>? headers, dynamic tag}) {
  final uri = Uri.parse(url);
  if (uri.host.endsWith('googlevideo.com')) {
    return ChunkedHttpAudioSource(uri, headers: headers ?? const {}, tag: tag);
  }
  return AudioSource.uri(
    uri,
    headers: (headers == null || headers.isEmpty) ? null : headers,
    tag: tag,
  );
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

/// Plays a YouTube (googlevideo) link by asking for it in small bounded pieces.
///
/// These links answer 403 to a request with no Range header, to an open-ended one
/// ("bytes=0-") and to any range bigger than about 1 MiB, while a range of 1 MiB or less gets
/// 206 (the app's probe lines showed exactly this). The player always starts a song with no
/// Range header, so it cannot open the link by itself. This source sits between: the player
/// asks it for a range, it fetches that range from YouTube in pieces of [_size] bytes and
/// hands the bytes over. Seeking works because the player's own range is passed on. If a
/// piece is refused with 403 the size is halved (down to [_minSize]) and remembered.
class ChunkedHttpAudioSource extends StreamAudioSource {
  ChunkedHttpAudioSource(this.uri, {Map<String, String> headers = const {}, super.tag})
      : headers = {
          for (final e in headers.entries)
            if (e.key.toLowerCase() != 'range') e.key: e.value,
        };

  final Uri uri;
  final Map<String, String> headers;

  static int _size = 1024 * 1024; // accepted in the probe; bigger ones got 403
  static const int _minSize = 128 * 1024;
  static const String _fallbackUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/141.0.0.0 Safari/537.36';
  static final HttpClient _client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

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
        final req = await _client.getUrl(uri);
        headers.forEach((k, v) => req.headers.set(k, v));
        if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
          req.headers.set(HttpHeaders.userAgentHeader, _fallbackUserAgent);
        }
        req.headers.set(HttpHeaders.rangeHeader, what);
        final res = await req.close().timeout(const Duration(seconds: 15));
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
  /// (exclusive, null when the length is unknown). A 403 halves the piece size and asks again.
  Future<_Piece> _openPiece(int from, int? limit) async {
    while (true) {
      final to = limit == null ? from + _size : min(from + _size, limit);
      try {
        return _Piece(await _open(from, to - 1), to);
      } on _Refused catch (e) {
        final span = to - from;
        if (e.status != 403 || span <= _minSize) {
          debugPrint('chunked source: failed, $e');
          rethrow;
        }
        _size = max(_minSize, span ~/ 2);
        debugPrint('chunked source: 403 for $span bytes, trying pieces of ${_size ~/ 1024} KiB');
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
