import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
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

class _Refused implements Exception {
  final int status;
  final String what;
  _Refused(this.status, this.what);
  @override
  String toString() => 'YouTube answered $status for $what';
}

/// Plays a YouTube (googlevideo) link by asking for it in bounded pieces, like yt-dlp does.
///
/// These links answer 403 to a request with no Range header and to an open-ended one
/// ("bytes=0-"), while a bounded range gets 206 (the app's probe lines showed this). The
/// player always starts a song with no Range header, so it cannot open the link by itself.
/// This source sits between: the player asks it for a range, it fetches that range from
/// YouTube in pieces of [_chunk] bytes and hands the bytes over. Seeking works because the
/// player's own range is passed on.
class ChunkedHttpAudioSource extends StreamAudioSource {
  ChunkedHttpAudioSource(this.uri, {Map<String, String> headers = const {}, super.tag})
      : headers = {
          for (final e in headers.entries)
            if (e.key.toLowerCase() != 'range') e.key: e.value,
        };

  final Uri uri;
  final Map<String, String> headers;

  static const int _chunk = 4 * 1024 * 1024; // a bounded piece (yt-dlp uses 10 MiB)
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
      } on _Refused catch (e) {
        debugPrint('chunked source: failed, $e');
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

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final sw = Stopwatch()..start();
    final from = start ?? 0;
    final known = _total ?? int.tryParse(uri.queryParameters['clen'] ?? '');
    final wantEnd = end ?? known; // exclusive; null while the length is unknown
    final firstEnd = wantEnd == null ? from + _chunk : min(from + _chunk, wantEnd);
    final first = await _open(from, firstEnd - 1);

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
      stream: _pieces(first, from, firstEnd, stopAt),
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
      final to = stopAt == null ? pos + _chunk : min(pos + _chunk, stopAt);
      res = await _open(pos, to - 1);
      asked = to;
    }
  }
}
