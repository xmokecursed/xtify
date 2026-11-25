import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_merge.dart';
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

  // Settings and history that an older version of Xtify kept in the plain
  // settings store. The first time they are moved here. After that, anything
  // found there was written later by an older version (after going back to
  // it), so it is joined with what is saved here instead of being left behind
  // or thrown away. Each plain copy is removed as soon as its joined value is
  // saved, so a key that cannot be saved right now never makes the others be
  // joined a second time at the next start (that would count plays twice).
  Future<void> _moveOldValues() async {
    final vault = Vault.instance;
    if (!vault.canWrite) return;
    final movedBefore = await vault.exists(_doneName);
    final old = await SharedPreferences.getInstance();
    var complete = true;
    for (final key in _oldKeys) {
      final value = old.get(key);
      if (value == null) continue;
      final have = _values[key];
      final next = have == null ? value : _join(key, have, value, newer: movedBefore);
      if (!_same(next, have)) {
        if (!await _save(key, next)) {
          // It stays where it is and is tried again at the next start.
          complete = false;
          continue;
        }
        _values[key] = next;
      }
      await old.remove(key);
    }
    if (!complete) return;
    for (final key in _staleKeys) {
      if (old.containsKey(key)) await old.remove(key);
    }
    if (!movedBefore) await vault.writeText(_doneName, '1');
  }

  // [have] is what is saved, [older] what an older version left in the plain
  // store. Lists are joined. Any other value is a single choice, and the older
  // one was set last, except during the very first move, where what is saved
  // is kept.
  static Object _join(String key, Object have, Object older, {required bool newer}) {
    if (have is List && older is List) {
      final a = [for (final e in have) '$e'];
      final b = [for (final e in older) '$e'];
      if (key == 'play_history') return DataMerge.history(a, b);
      if (key == 'artist_stats') return DataMerge.artistStats(a, b);
      if (key == 'search_history') return DataMerge.queries(a, b);
    }
    return newer ? older : have;
  }

  static bool _same(Object? a, Object? b) =>
      a != null && b != null && jsonEncode(a) == jsonEncode(b);

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
