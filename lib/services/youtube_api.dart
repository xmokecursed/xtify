import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'hedged.dart';
import 'innertube_client.dart';

enum YouTubeSurface { web, music }

class YouTubeApiException implements Exception {
  final String message;
  final int? status;
  final bool transient;
  const YouTubeApiException(this.message, {this.status, this.transient = false});

  bool get throttled => status == 429 || status == 403;

  @override
  String toString() => message;
}

Object? _decodeJson(String text) => jsonDecode(text);

class YouTubeApi {
  YouTubeApi._();

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/149.0.0.0 Safari/537.36';
  static const int _decodeApart = 64 * 1024;

  static HttpClient? _httpClient;
  static HttpClient get _http => _httpClient ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 6)
    ..idleTimeout = const Duration(seconds: 60);

  static DateTime _identityFailedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<InnertubeIdentity?> _identity() async {
    if (DateTime.now().difference(_identityFailedAt) < const Duration(minutes: 1)) return null;
    try {
      return await InnertubeClient.identity().timeout(const Duration(seconds: 6));
    } catch (_) {
      _identityFailedAt = DateTime.now();
      return null;
    }
  }

  static String _version(String major) {
    final d = DateTime.now().toUtc().subtract(const Duration(days: 2));
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '$major.${d.year}$month$day.01.00';
  }

  static Future<Map<String, dynamic>> post(
    String endpoint,
    Map<String, Object?> body, {
    YouTubeSurface surface = YouTubeSurface.web,
  }) {
    return hedged<Map<String, dynamic>>(
      () => _once(endpoint, body, surface),
      after: const Duration(milliseconds: 3500),
      tries: 2,
      limit: const Duration(seconds: 12),
      fatal: (e) => e is YouTubeApiException && !e.transient,
    );
  }

  static Future<Map<String, dynamic>> _once(
    String endpoint,
    Map<String, Object?> body,
    YouTubeSurface surface,
  ) async {
    final music = surface == YouTubeSurface.music;
    final who = await _identity();
    final version = _version(music ? '1' : '2');
    final origin = music ? 'https://music.youtube.com' : 'https://www.youtube.com';
    final payload = utf8.encode(jsonEncode(<String, Object?>{
      'context': <String, Object?>{
        'client': <String, Object?>{
          'clientName': music ? 'WEB_REMIX' : 'WEB',
          'clientVersion': version,
          'hl': 'en',
          'timeZone': 'UTC',
          'utcOffsetMinutes': 0,
          if (who != null) 'visitorData': who.visitor,
        },
        'user': <String, Object?>{'lockedSafetyMode': false},
      },
      ...body,
    }));
    final req = await _http.postUrl(Uri.parse('$origin/youtubei/v1/$endpoint?prettyPrint=false'));
    req.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.5')
      ..set('Origin', origin)
      ..set('X-YouTube-Client-Name', music ? '67' : '1')
      ..set('X-YouTube-Client-Version', version);
    if (who != null) {
      req.headers
        ..set('X-Goog-Visitor-Id', who.visitor)
        ..set(HttpHeaders.cookieHeader, who.cookies);
    }
    req.contentLength = payload.length;
    req.add(payload);
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw YouTubeApiException(
        'YouTube answered HTTP ${res.statusCode}',
        status: res.statusCode,
        transient: res.statusCode >= 500,
      );
    }
    final text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
    final Object? decoded =
        text.length > _decodeApart ? await compute(_decodeJson, text) : jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const YouTubeApiException('YouTube answered with something unexpected');
    }
    return decoded;
  }
}

class YtJson {
  YtJson._();

  static Map<String, dynamic>? map(Object? v) => v is Map<String, dynamic> ? v : null;

  static List<dynamic> list(Object? v) => v is List<dynamic> ? v : const <dynamic>[];

  static String str(Object? v) => v is String ? v : '';

  static void _walk(
    Object? node,
    Set<String> keys,
    Set<String> skip,
    List<Map<String, dynamic>> out,
  ) {
    if (node is Map<String, dynamic>) {
      for (final e in node.entries) {
        if (skip.contains(e.key)) continue;
        final v = e.value;
        if (v is Map<String, dynamic> && keys.contains(e.key)) out.add(v);
        _walk(v, keys, skip, out);
      }
    } else if (node is List<dynamic>) {
      for (final v in node) {
        _walk(v, keys, skip, out);
      }
    }
  }

  static List<Map<String, dynamic>> allOf(
    Object? node,
    Set<String> keys, {
    Set<String> skip = const <String>{},
  }) {
    final out = <Map<String, dynamic>>[];
    _walk(node, keys, skip, out);
    return out;
  }

  static List<Map<String, dynamic>> all(
    Object? node,
    String key, {
    Set<String> skip = const <String>{},
  }) =>
      allOf(node, <String>{key}, skip: skip);

  static List<Map<String, dynamic>> runs(Object? node) {
    final out = <Map<String, dynamic>>[];
    for (final r in list(map(node)?['runs'])) {
      final m = map(r);
      if (m != null) out.add(m);
    }
    return out;
  }

  static String text(Object? node) {
    final m = map(node);
    if (m == null) return '';
    final simple = m['simpleText'];
    if (simple is String) return simple;
    final b = StringBuffer();
    for (final r in runs(m)) {
      b.write(str(r['text']));
    }
    return b.toString();
  }

  static String browseId(Object? node) {
    final endpoint = map(map(node)?['navigationEndpoint']);
    return str(map(endpoint?['browseEndpoint'])?['browseId']);
  }

  static int seconds(String text) {
    final parts = text.trim().split(':');
    if (parts.length < 2 || parts.length > 3) return 0;
    var total = 0;
    for (final p in parts) {
      final n = int.tryParse(p.trim());
      if (n == null || n < 0) return 0;
      total = total * 60 + n;
    }
    return total;
  }

  static String continuation(Object? response) {
    var token = '';
    for (final c in all(response, 'continuationItemRenderer')) {
      final command = map(map(c['continuationEndpoint'])?['continuationCommand']);
      final t = str(command?['token']);
      if (t.isNotEmpty) token = t;
    }
    return token;
  }
}
