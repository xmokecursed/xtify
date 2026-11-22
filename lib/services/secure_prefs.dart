import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'vault.dart';

class SecurePrefs {
  SecurePrefs._(this._values, this._onDisk);

  static const String _prefix = 'p.';
  static const String _doneName = 'p._moved';

  static const List<String> _oldKeys = [
    'play_history',
    'artist_stats',
    'search_history',
    'artist_mixes_v2',
    'artist_mixes_v1',
    'feed_trending',
    'last_pos_ms',
    'volume',
    'yt_signed_in',
    'yt_cookies_last_refresh',
    'auto_queue_mode_v1',
    'preferred_strategy_v5',
    'yt_dlp_version_v1',
    'yt_dlp_last_update',
    'download_dir_v1',
  ];

  static const List<String> _staleKeys = ['feed_made_for_you', 'feed_made_sig'];

  static Future<SecurePrefs>? _pending;

  final Map<String, Object> _values;
  final Set<String> _onDisk;

  static Future<SecurePrefs> getInstance() => _pending ??= _open();

  static Future<SecurePrefs> _open() async {
    final vault = Vault.instance;
    await vault.init();
    final values = <String, Object>{};
    final onDisk = <String>{};
    for (final name in await vault.names(_prefix)) {
      final key = name.substring(_prefix.length);
      if (key.isEmpty || key.startsWith('_')) continue;
      onDisk.add(key);
      final text = await vault.readText(name);
      if (text == null) continue;
      try {
        final value = jsonDecode(text);
        if (value != null) values[key] = value as Object;
      } catch (e) {
        debugPrint('prefs: could not read $key: $e');
      }
    }
    final prefs = SecurePrefs._(values, onDisk);
    try {
      await prefs._moveOldValues();
    } catch (e) {
      debugPrint('prefs: could not move the old settings: $e');
    }
    return prefs;
  }

  Future<void> _moveOldValues() async {
    final vault = Vault.instance;
    if (!vault.canWrite) return;
    if (await vault.exists(_doneName)) return;
    final old = await SharedPreferences.getInstance();
    var complete = true;
    final moved = <String>[];
    for (final key in _oldKeys) {
      final value = old.get(key);
      if (value == null) continue;
      if (!_values.containsKey(key)) {
        if (!await _save(key, value)) {
          complete = false;
          continue;
        }
        _values[key] = value;
      }
      moved.add(key);
    }
    if (!complete) return;
    for (final key in moved) {
      await old.remove(key);
    }
    for (final key in _staleKeys) {
      if (old.containsKey(key)) await old.remove(key);
    }
    await vault.writeText(_doneName, '1');
  }

  Future<bool> _save(String key, Object value, {bool durable = true}) {
    _onDisk.add(key);
    final text = jsonEncode(value);
    return Vault.instance.writeText(
      '$_prefix$key',
      text,
      backup: text.length > 512,
      durable: durable,
    );
  }

  Future<bool> _set(String key, Object value, {bool durable = true}) {
    _values[key] = value;
    return _save(key, value, durable: durable);
  }

  bool containsKey(String key) => _values.containsKey(key);

  String? getString(String key) {
    final value = _values[key];
    return value is String ? value : null;
  }

  int? getInt(String key) {
    final value = _values[key];
    return value is int ? value : null;
  }

  double? getDouble(String key) {
    final value = _values[key];
    return value is num ? value.toDouble() : null;
  }

  bool? getBool(String key) {
    final value = _values[key];
    return value is bool ? value : null;
  }

  List<String>? getStringList(String key) {
    final value = _values[key];
    return value is List ? [for (final e in value) '$e'] : null;
  }

  Future<bool> setString(String key, String value) => _set(key, value);

  Future<bool> setInt(String key, int value) => _set(key, value, durable: false);

  Future<bool> setDouble(String key, double value) => _set(key, value, durable: false);

  Future<bool> setBool(String key, bool value) => _set(key, value, durable: false);

  Future<bool> setStringList(String key, List<String> value) =>
      _set(key, List<String>.of(value));

  Future<bool> remove(String key) async {
    _values.remove(key);
    if (_onDisk.remove(key)) await Vault.instance.delete('$_prefix$key');
    return true;
  }
}
