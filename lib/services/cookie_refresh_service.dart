import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cookie_service.dart';

class CookieRefreshService {
  CookieRefreshService._();
  static final CookieRefreshService instance = CookieRefreshService._();

  static const String _lastKey = 'yt_cookies_last_refresh';
  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 12; SM-G998N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36';

  bool _running = false;
  DateTime _lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> refreshIfOlderThan(Duration maxAge) async {
    try {
      if (_running) return;
      if (DateTime.now().difference(_lastAttempt) < const Duration(minutes: 5)) return;
      if (!CookieService.instance.signedInListener.value) return;
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastKey) ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - last < maxAge.inMilliseconds) return;
      await _refresh(prefs);
    } catch (e) {
      debugPrint('Cookie refresh error: $e');
    }
  }

  Future<void> _refresh(SharedPreferences prefs) async {
    _running = true;
    _lastAttempt = DateTime.now();
    HeadlessInAppWebView? web;
    try {
      final loaded = Completer<void>();
      web = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('https://www.youtube.com/')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent: _userAgent,
        ),
        onLoadStop: (controller, url) {
          if (!loaded.isCompleted) loaded.complete();
        },
      );
      await web.run();
      await loaded.future.timeout(const Duration(seconds: 25));
      await Future.delayed(const Duration(seconds: 6));

      if (!await CookieService.instance.hasAuthCookieInWebView()) {
        debugPrint('Cookie refresh: WebView has no auth cookie; keeping old file');
        CookieService.instance.markExpired();
        return;
      }
      await CookieService.instance.saveFromWebView();
      await prefs.setInt(_lastKey, DateTime.now().millisecondsSinceEpoch);
      debugPrint('Cookie refresh: saved');
    } catch (e) {
      debugPrint('Cookie refresh failed: $e');
    } finally {
      _running = false;
      try {
        await web?.dispose();
      } catch (_) {}
    }
  }
}
