import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'hedged.dart';

const String _fallbackUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/141.0.0.0 Safari/537.36';

final HttpClient _http = HttpClient()
  ..autoUncompress = false
  ..connectionTimeout = const Duration(seconds: 8)
  ..idleTimeout = const Duration(seconds: 30);

bool _isDirectMedia(Uri uri) =>
    uri.host.endsWith('googlevideo.com') && uri.path.contains('videoplayback');

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

Future<HttpClientResponse> _rangeRequest(
    Uri uri, Map<String, String> headers, int from, int toInclusive,
    {int tries = 3, Duration limit = const Duration(seconds: 12)}) {
  Future<HttpClientResponse> attempt() async {
    final sw = Stopwatch()..start();
    final req = await _http.getUrl(uri);
    final connected = sw.elapsedMilliseconds;
    try {
      headers.forEach((k, v) => req.headers.set(k, v));
      if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        req.headers.set(HttpHeaders.userAgentHeader, _fallbackUserAgent);
      }
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$toInclusive');
      final res = await req.close().timeout(const Duration(seconds: 10));
      final total = sw.elapsedMilliseconds;
      if (total > 1500) {
        debugPrint('slow answer from ${uri.host}: connected after ${connected}ms, '
            'headers after ${total}ms');
      }
      return res;
    } catch (_) {
      req.abort();
      rethrow;
    }
  }

  return hedged<HttpClientResponse>(
    attempt,
    tries: tries,
    limit: limit,
    discard: _letGo,
    onExtra: (n) =>
        debugPrint('no answer from ${uri.host} yet, asking again on a new connection (try $n)'),
  );
}

void _letGo(HttpClientResponse res) {
  unawaited(res.listen(null).cancel());
}

String _why(Object e) {
  if (e is SocketException) {
    final os = e.osError;
    final text = e.message.startsWith('HTTP connection timed out')
        ? 'connecting took too long'
        : e.message;
    return 'SocketException: $text${os == null ? '' : ' (${os.message}, code ${os.errorCode})'}';
  }
  if (e is TimeoutException) return 'TimeoutException: no answer in time';
  return e.runtimeType.toString();
}

Future<String?> linkProblem(String url,
    {Map<String, String> headers = const {},
    Duration wait = const Duration(seconds: 2),
    void Function(String problem)? onLate}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !_isDirectMedia(uri)) return Future<String?>.value(null);
  final answer = Completer<String?>();
  final timer = Timer(wait, () {
    if (answer.isCompleted) return;
    debugPrint('link check: no answer after ${wait.inMilliseconds}ms, going on without it');
    answer.complete(null);
  });
  unawaited(_checkLink(uri, headers).then<void>((bad) {
    timer.cancel();
    if (!answer.isCompleted) {
      answer.complete(bad);
    } else if (bad != null) {
      debugPrint('link check, late: $bad');
      onLate?.call(bad);
    }
  }));
  return answer.future;
}

Future<String?> _checkLink(Uri uri, Map<String, String> headers) async {
  final clen = int.tryParse(uri.queryParameters['clen'] ?? '');
  final at = clen == null ? 0 : max(0, min(clen - 2, max(1310720, clen ~/ 2)));
  final what = 'bytes=$at-${at + 1}';
  final sw = Stopwatch()..start();
  try {
    final res = await _rangeRequest(uri, headers, at, at + 1,
        tries: 2, limit: const Duration(seconds: 10));
    final code = res.statusCode;
    try {
      if (code == 206 || code >= 400) {
        await res.drain<void>().timeout(const Duration(seconds: 3));
      } else {
        await res.first.timeout(const Duration(seconds: 3));
      }
    } catch (_) {}
    if (code == 200 || code == 206) {
      debugPrint('link works: HTTP $code for $what, took ${sw.elapsedMilliseconds}ms');
      return null;
    }
    if (code >= 400 && code < 500 && code != 429 && code != 416) return 'HTTP $code for $what';
    debugPrint('link check skipped: HTTP $code for $what');
    return null;
  } catch (e) {
    debugPrint('link check skipped (${_why(e)}) after ${sw.elapsedMilliseconds}ms');
    return null;
  }
}

class _Piece {
  final HttpClientResponse res;
  final int to;
  _Piece(this.res, this.to);
}

class _Refused implements Exception {
  final int status;
  final String what;
  _Refused(this.status, this.what);
  @override
  String toString() => 'YouTube answered $status for $what';
}

class ChunkedHttpAudioSource extends StreamAudioSource {
  ChunkedHttpAudioSource(this.uri, {Map<String, String> headers = const {}, super.tag})
      : headers = {
          for (final e in headers.entries)
            if (e.key.toLowerCase() != 'range') e.key: e.value,
        };

  final Uri uri;
  final Map<String, String> headers;

  int _size = 4 * 1024 * 1024;
  static const int _minSize = 256 * 1024;

  int? _total;

  String get _type {
    final m = uri.queryParameters['mime'];
    return (m != null && m.contains('/')) ? m : 'audio/mp4';
  }

  Future<HttpClientResponse> _open(int from, int toInclusive) async {
    final what = 'bytes=$from-$toInclusive';
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
      debugPrint('chunked source: $what failed (${_why(e)})');
      rethrow;
    }
  }

  Future<_Piece> _openPiece(int from, int? limit) async {
    var size = _size;
    while (true) {
      final to = limit == null ? from + size : min(from + size, limit);
      try {
        final piece = _Piece(await _open(from, to - 1), to);
        if (size < _size) {
          _size = size;
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
    final wantEnd = end ?? known;
    final piece = await _openPiece(from, wantEnd);
    final first = piece.res;

    var total = known;
    if (first.statusCode == 200) {
      if (first.contentLength >= 0) total = first.contentLength;
    } else {
      final range = first.headers.value(HttpHeaders.contentRangeHeader) ?? '';
      final m = RegExp(r'/(\d+)\s*$').firstMatch(range);
      if (m != null) total = int.parse(m[1]!);
    }
    _total = total;
    final stopAt = end ?? total;
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

  Stream<List<int>> _pieces(HttpClientResponse first, int from, int firstEnd, int? stopAt) async* {
    var pos = from;
    var res = first;
    var asked = firstEnd;
    while (true) {
      var got = 0;
      await for (final data in res.timeout(const Duration(seconds: 20))) {
        got += data.length;
        pos += data.length;
        yield data;
      }
      if (res.statusCode == 200) return;
      if (got == 0) return;
      if (stopAt != null && pos >= stopAt) return;
      if (stopAt == null && pos < asked) return;
      final next = await _openPiece(pos, stopAt);
      res = next.res;
      asked = next.to;
    }
  }
}
