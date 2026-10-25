import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CookieService {
  CookieService._internal();
  static final CookieService _instance = CookieService._internal();
  static CookieService get instance => _instance;

  static const String _signedInKey = 'yt_signed_in';
  static const String _cookieFileName = 'youtube_cookies.txt';
  static const Set<String> _authNames = {
    'SAPISID', '__Secure-1PSID', '__Secure-3PSID', 'SID',
  };

  final ValueNotifier<bool> _signedInNotifier = ValueNotifier<bool>(false);
  ValueListenable<bool> get signedInListener => _signedInNotifier;

  /// True when YouTube stopped accepting the saved sign-in (shows the "Sign in again" banner).
  final ValueNotifier<bool> _needsSignInNotifier = ValueNotifier<bool>(false);
  ValueListenable<bool> get needsSignInListener => _needsSignInNotifier;

  void markExpired() {
    if (_signedInNotifier.value && !_needsSignInNotifier.value) {
      _needsSignInNotifier.value = true;
    }
  }

  /// True when a yt-dlp / player error looks like "YouTube wants you signed in".
  static bool looksLikeAuthError(String message) {
    final m = message.toLowerCase();
    return m.contains('sign in to confirm') ||
        m.contains('not a bot') ||
        m.contains('login required') ||
        m.contains('cookies are no longer valid') ||
        m.contains('not signed in');
  }

  Future<void> init() async {
    await _loadSignedInStatus();
  }

  Future<void> _loadSignedInStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final signedInFromPrefs = prefs.getBool(_signedInKey) ?? false;
    final signedInFromCookie = await isSignedIn();
    _signedInNotifier.value = signedInFromPrefs || signedInFromCookie;
  }

  Future<bool> isSignedIn() async {
    final file = await cookieFile();
    if (file == null) {
      return false;
    }
    // Check for auth cookie by name
    try {
      final content = await file.readAsString();
      final lines = content.split('\n');
      for (final line in lines) {
        if (line.startsWith('#')) {
          continue;
        }
        final parts = line.split('\t');
        if (parts.length >= 7 && _authNames.contains(parts[5])) {
          return true;
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error reading cookie file: $e');
      }
    }
    return false;
  }

  Future<File?> cookieFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_cookieFileName');
      if (await file.exists()) {
        return file;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error getting cookie file: $e');
      }
    }
    return null;
  }

  Future<List<Cookie>> _collectWebViewCookies() async {
    final manager = CookieManager.instance();
    final out = <Cookie>[];
    final seen = <String>{};
    for (final u in const [
      'https://www.youtube.com',
      'https://accounts.google.com',
      'https://www.google.com',
    ]) {
      final list = await manager.getCookies(url: WebUri(u));
      for (final c in list) {
        if (seen.add('${c.domain}|${c.path}|${c.name}')) {
          out.add(c);
        }
      }
    }
    return out;
  }

  bool _hasAuth(List<Cookie> cookies) => cookies.any(
        (c) => _authNames.contains(c.name) && (c.value ?? '').toString().isNotEmpty,
      );

  Future<bool> hasAuthCookieInWebView() async {
    try {
      return _hasAuth(await _collectWebViewCookies());
    } catch (e) {
      debugPrint('Error checking auth cookie in webview: $e');
      return false;
    }
  }

  Future<void> saveFromWebView() async {
    try {
      final allCookies = await _collectWebViewCookies();
      if (allCookies.isEmpty) {
        throw Exception('No cookies found to save');
      }

      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final file = File('${dir.path}/$_cookieFileName');
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(_generateNetscapeCookieString(allCookies), flush: true);
      await tmp.rename(file.path);

      final signedIn = _hasAuth(allCookies); // from memory, not by re-reading the file
      _signedInNotifier.value = signedIn;
      if (signedIn) _needsSignInNotifier.value = false; // fresh sign-in: notice goes away

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_signedInKey, signedIn);

      if (kDebugMode) {
        debugPrint('Cookie file saved: ${allCookies.length} cookies, signed in: $signedIn');
      }
    } on Exception catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to save cookies: $e');
      }
      rethrow;
    }
  }

  String _generateNetscapeCookieString(List<Cookie> cookies) {
    final lines = ['# Netscape HTTP Cookie File'];
    for (final cookie in cookies) {
      // Skip cookies with no value
      if (cookie.value == null || cookie.value!.isEmpty) {
        continue;
      }
      final domain = cookie.domain ?? '';
      final includeSubdomains = domain.startsWith('.') ? 'TRUE' : 'FALSE';
      final path = cookie.path ?? '/';
      final secure = cookie.isSecure ?? false ? 'TRUE' : 'FALSE';
      final expiryDate = cookie.expiresDate;
      final expiry = expiryDate != null
          ? DateTime.fromMillisecondsSinceEpoch(expiryDate)
          : DateTime.now().add(const Duration(days: 365 * 10)); // far future
      final expiryEpoch = expiry.millisecondsSinceEpoch ~/ 1000;
      final name = cookie.name;
      final value = cookie.value;
      // Prefix domain with #HttpOnly_ if it's HttpOnly
      final prefixedDomain = cookie.isHttpOnly ?? false ? '#HttpOnly_$domain' : domain;
      lines.add([
        prefixedDomain,
        includeSubdomains,
        path,
        secure,
        expiryEpoch.toString(),
        name,
        value,
      ].join('\t'));
    }
    return lines.join('\n');
  }

  /// Gets the cookie header string for YouTube domains from the cookie file.
  /// Returns null if no cookie file exists or no YouTube cookies found.
  Future<String?> getYouTubeCookieHeader() async {
    final file = await cookieFile();
    if (file == null) {
      return null;
    }
    try {
      final content = await file.readAsString();
      final lines = content.split('\n');
      final List<String> cookieLines = [];
      for (final line in lines) {
        if (line.startsWith('#')) {
          continue;
        }
        final parts = line.split('\t');
        if (parts.length >= 7) {
          final domain = parts[0];
          // Check if domain is for YouTube (including subdomains)
          if (domain.contains('youtube.com')) {
            final name = parts[5];
            final value = parts[6];
            if (name.isNotEmpty && value.isNotEmpty) {
              cookieLines.add('$name=$value');
            }
          }
        }
      }
      if (cookieLines.isEmpty) {
        return null;
      }
      return cookieLines.join('; ');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error getting YouTube cookie header: $e');
      }
      return null;
    }
  }

  Future<void> signOut() async {
    try {
      // Delete cookie file
      final file = await cookieFile();
      if (file != null) {
        await file.delete();
      }

      // Clear WebView cookies for youtube.com and google.com
      await CookieManager.instance().deleteCookies(
        url: WebUri('https://www.youtube.com'),
      );
      await CookieManager.instance().deleteCookies(
        url: WebUri('https://accounts.google.com'),
      );

      // Update sign-in status
      _signedInNotifier.value = false;
      _needsSignInNotifier.value = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_signedInKey, false);

      if (kDebugMode) {
        debugPrint('Signed out and cookies cleared');
      }
    } on Exception catch (e) {
      if (kDebugMode) {
        debugPrint('Error during sign out: $e');
      }
      rethrow;
    }
  }
}
