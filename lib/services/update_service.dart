import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import '../desktop/desktop_scope.dart' show isDesktopPlatform;
import 'connectivity_service.dart';

class UpdateInfo {
  final String version;
  final String url;

  const UpdateInfo({required this.version, required this.url});
}

List<int>? parseVersion(String text) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(text.trim());
  if (m == null) return null;
  final major = int.tryParse(m.group(1)!);
  final minor = int.tryParse(m.group(2)!);
  final patch = int.tryParse(m.group(3)!);
  if (major == null || minor == null || patch == null) return null;
  return [major, minor, patch];
}

bool isNewerVersion(String remote, String local) {
  final a = parseVersion(remote);
  final b = parseVersion(local);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

String? versionFromPubspec(String pubspec) {
  final m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true).firstMatch(pubspec);
  return m?.group(1);
}

class UpdateService {
  UpdateService._();
  static final UpdateService instance = UpdateService._();

  static const String _base = 'https://xtify-backend.onrender.com';
  static const Duration _timeout = Duration(seconds: 90);
  static const Duration _interval = Duration(hours: 6);
  static const Duration _retryDelay = Duration(minutes: 3);
  static const int _maxRetries = 2;

  final ValueNotifier<UpdateInfo?> available = ValueNotifier<UpdateInfo?>(null);

  bool _started = false;
  bool _checking = false;
  bool _answered = false;
  int _retries = 0;

  void start() {
    if (_started) return;
    _started = true;
    ConnectivityService.instance.online.addListener(_onConnectivity);
    Timer.periodic(_interval, (_) => check());
    if (ConnectivityService.instance.online.value) check();
  }

  void _onConnectivity() {
    if (!ConnectivityService.instance.online.value || _answered) return;
    _retries = 0;
    check();
  }

  Future<void> check() async {
    if (_checking) return;
    _checking = true;
    var retry = false;
    try {
      final local = versionFromPubspec(await rootBundle.loadString('pubspec.yaml'));
      if (local == null) return;
      final platform = isDesktopPlatform ? 'desktop' : 'android';
      final res = await http.get(Uri.parse('$_base/version/$platform')).timeout(_timeout);
      if (res.statusCode != 200) {
        retry = true;
        return;
      }
      final info = _parse(res.body);
      if (info == null) return;
      _answered = true;
      _retries = 0;
      available.value = isNewerVersion(info.version, local) ? info : null;
    } catch (e) {
      debugPrint('update check failed: $e');
      retry = true;
    } finally {
      _checking = false;
      if (retry && _retries < _maxRetries) {
        _retries++;
        Timer(_retryDelay, check);
      }
    }
  }

  static UpdateInfo? _parse(String body) {
    final data = jsonDecode(body);
    if (data is! Map) return null;
    final version = data['version'];
    final url = data['url'];
    if (version is! String || url is! String) return null;
    if (parseVersion(version) == null) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return UpdateInfo(version: version.trim(), url: url);
  }
}
