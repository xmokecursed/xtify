import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'secure_prefs.dart';
import 'vault.dart';

class CookieLoan {
  CookieLoan._(this._file, this._original) {
    _expiry = Timer(_lifetime, () => unawaited(giveBack()));
  }

  static const Duration _lifetime = Duration(minutes: 3);

  final File _file;
  final String _original;
  late final Timer _expiry;
  bool _returned = false;

  String get path => _file.path;

  Future<void> giveBack() async {
    if (_returned) return;
    _returned = true;
    _expiry.cancel();
    await CookieService.instance._takeBack(_file, _original);
  }
}

class CookieService {
  CookieService._internal();
  static final CookieService _instance = CookieService._internal();
  static CookieService get instance => _instance;

  static const String _signedInKey = 'yt_signed_in';
  static const String _jarName = 'yt-cookies';
  static const String _legacyFileName = 'youtube_cookies.txt';
  static const String _loanFolder = 'ytdlp-cookies';
  static const Set<String> _authNames = {
    'SAPISID', '__Secure-1PSID', '__Secure-3PSID', 'SID',
  };

  final ValueNotifier<bool> _signedInNotifier = ValueNotifier<bool>(false);
  ValueListenable<bool> get signedInListener => _signedInNotifier;

  final ValueNotifier<bool> _needsSignInNotifier = ValueNotifier<bool>(false);
  ValueListenable<bool> get needsSignInListener => _needsSignInNotifier;

  void markExpired() {
    if (_signedInNotifier.value && !_needsSignInNotifier.value) {
      _needsSignInNotifier.value = true;
    }
  }

  static bool looksLikeAuthError(String message) {
    final m = message.toLowerCase();
    return m.contains('sign in to confirm') ||
        m.contains('not a bot') ||
        m.contains('login required') ||
        m.contains('cookies are no longer valid') ||
        m.contains('not signed in');
  }

  Future<void> init() async {
    await _moveLegacyFile();
    await _sweepLoans();
    await _loadSignedInStatus();
  }

  Future<void> _loadSignedInStatus() async {
    final prefs = await SecurePrefs.getInstance();
    final signedInFromPrefs = prefs.getBool(_signedInKey) ?? false;
    final signedInFromCookie = await isSignedIn();
    _signedInNotifier.value = signedInFromPrefs || signedInFromCookie;
  }

  Future<bool> isSignedIn() async {
    try {
      final jar = await _readJar();
      return jar != null && _hasAuthLine(jar);
    } catch (e) {
      debugPrint('Error reading the saved cookies: $e');
      return false;
    }
  }

  Future<bool> hasCookies() async {
    try {
      return await _readJar() != null;
    } catch (e) {
      debugPrint('Error reading the saved cookies: $e');
      return false;
    }
  }

  Future<CookieLoan?> lend() async {
    try {
      final jar = await _readJar();
      if (jar == null) return null;
      final dir = await _loanDirectory();
      final file = File(
        '${dir.path}${Platform.pathSeparator}jar-${DateTime.now().microsecondsSinceEpoch}.txt',
      );
      await file.writeAsString(jar, flush: true);
      return CookieLoan._(file, jar);
    } catch (e) {
      debugPrint('Could not prepare the cookie file for yt-dlp: $e');
      return null;
    }
  }

  Future<void> _takeBack(File file, String original) async {
    try {
      if (await file.exists()) {
        final after = await file.readAsString();
        if (_hasAuthLine(after) &&
            !setEquals(_dataLines(after), _dataLines(original))) {
          await Vault.instance.writeText(_jarName, after);
        }
      }
    } catch (e) {
      debugPrint('Could not read the cookie file back from yt-dlp: $e');
    }
    await Vault.wipe(file);
  }

  Future<Directory> _loanDirectory() async {
    final base = await getTemporaryDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$_loanFolder');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _sweepLoans() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}$_loanFolder');
      if (!await dir.exists()) return;
      final left = await dir.list(followLinks: false).where((e) => e is File).toList();
      for (final file in left) {
        await Vault.wipe(file as File);
      }
    } catch (e) {
      debugPrint('Could not clean the temporary cookie folder: $e');
    }
  }

  Future<String?> _readJar() async {
    final stored = await Vault.instance.readText(_jarName);
    if (stored != null && stored.trim().isNotEmpty) return stored;
    final legacy = await _legacyFile();
    if (legacy == null) return null;
    final text = await legacy.readAsString();
    return text.trim().isEmpty ? null : text;
  }

  Future<File?> _legacyFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}$_legacyFileName');
      return await file.exists() ? file : null;
    } catch (e) {
      debugPrint('Error looking for the old cookie file: $e');
      return null;
    }
  }

  Future<void> _moveLegacyFile() async {
    try {
      final legacy = await _legacyFile();
      if (legacy == null) {
        await _removeLegacyFiles();
        return;
      }
      final vault = Vault.instance;
      await vault.init();
      if (!vault.canWrite) return;
      var stored = await vault.readText(_jarName);
      if (stored == null || stored.trim().isEmpty) {
        final text = await legacy.readAsString();
        if (text.trim().isNotEmpty) {
          if (!await vault.writeText(_jarName, text)) return;
          stored = await vault.readText(_jarName);
          if (stored == null || stored != text) return;
        }
      }
      await _removeLegacyFiles();
      debugPrint('The saved sign-in cookies are now stored encrypted');
    } catch (e) {
      debugPrint('Could not move the old cookie file: $e');
    }
  }

  Future<void> _removeLegacyFiles() async {
    try {
      final dir = await getApplicationSupportDirectory();
      for (final name in const [_legacyFileName, '$_legacyFileName.tmp']) {
        await Vault.wipe(File('${dir.path}${Platform.pathSeparator}$name'));
      }
    } catch (e) {
      debugPrint('Could not remove the old cookie file: $e');
    }
  }

  static bool _hasAuthLine(String jar) {
    for (final raw in jar.split('\n')) {
      var line = raw;
      if (line.startsWith('#HttpOnly_')) {
        line = line.substring('#HttpOnly_'.length);
      } else if (line.startsWith('#')) {
        continue;
      }
      final parts = line.split('\t');
      if (parts.length >= 7 && _authNames.contains(parts[5]) && parts[6].trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static Set<String> _dataLines(String jar) => {
        for (final line in jar.split('\n'))
          if (line.trim().isNotEmpty && (!line.startsWith('#') || line.startsWith('#HttpOnly_')))
            line.trimRight(),
      };

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

      final saved = await Vault.instance
          .writeText(_jarName, _generateNetscapeCookieString(allCookies));
      if (!saved) {
        throw Exception('The cookies could not be saved securely on this device');
      }
      await _removeLegacyFiles();

      final signedIn = _hasAuth(allCookies);
      _signedInNotifier.value = signedIn;
      if (signedIn) _needsSignInNotifier.value = false;

      final prefs = await SecurePrefs.getInstance();
      await prefs.setBool(_signedInKey, signedIn);

      if (kDebugMode) {
        debugPrint('Cookies saved: ${allCookies.length} cookies, signed in: $signedIn');
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
          : DateTime.now().add(const Duration(days: 365 * 10));
      final expiryEpoch = expiry.millisecondsSinceEpoch ~/ 1000;
      final name = cookie.name;
      final value = cookie.value;
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

  Future<void> signOut() async {
    try {
      await Vault.instance.delete(_jarName);
      await _removeLegacyFiles();

      await CookieManager.instance().deleteCookies(
        url: WebUri('https://www.youtube.com'),
      );
      await CookieManager.instance().deleteCookies(
        url: WebUri('https://accounts.google.com'),
      );

      _signedInNotifier.value = false;
      _needsSignInNotifier.value = false;
      final prefs = await SecurePrefs.getInstance();
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
