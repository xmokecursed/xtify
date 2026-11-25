import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'vault_crypto.dart';

enum VaultState { starting, on, off, locked }

class Vault {
  Vault._();
  static final Vault instance = Vault._();

  static const MethodChannel _channel = MethodChannel('xtify/vault');
  static const List<int> _keyMagic = [0x58, 0x4B, 0x31];
  static const int _providerNone = 0;
  static const int _providerAndroid = 1;
  static const int _providerWindows = 2;
  static const Duration _callTimeout = Duration(seconds: 8);
  static const Set<String> _verdictCodes = {'key_missing', 'bad_blob', 'key_mismatch', 'dpapi'};
  static const int _backgroundFrom = 192 * 1024;
  static const int _wipeUpTo = 8 * 1024 * 1024;
  static const String _recordLabel = 'xtify-records/v1';
  static final RegExp _safeName = RegExp(r'^[A-Za-z0-9._-]{1,120}$');

  VaultState _state = VaultState.starting;
  String _detail = '';
  String _kind = '';
  bool _keyGone = false;
  Directory? _dir;
  VaultCrypto? _box;
  Future<void>? _ready;
  final Map<String, Future<void>> _tails = <String, Future<void>>{};
  final Map<String, String> _notes = <String, String>{};
  final Set<String> _newer = <String>{};
  final Set<String> _blocked = <String>{};
  final Set<String> _verified = <String>{};
  bool _startedFresh = false;

  // Things the user should know about. The notice at the top of the app shows them.
  final ValueNotifier<List<String>> notices = ValueNotifier<List<String>>(const <String>[]);

  // The saved items that a newer version of Xtify wrote. They are left as they are.
  List<String> get newerItems => List<String>.unmodifiable(_newer);

  VaultState get state => _state;

  bool get canWrite => _state == VaultState.on || _state == VaultState.off;

  // True when the vault is locked and the key storage said clearly that the
  // saved key can never be opened again. Only then is startFresh offered.
  bool get canStartFresh => _state == VaultState.locked && _keyGone;

  // True after startFresh moved the old files aside. The new key is made the
  // next time Xtify starts, so until then nothing can be saved.
  bool get startedFresh => _startedFresh;

  // A saved item that this run must not change: a newer version wrote it, or
  // it could not be read, so what the app holds in memory may not be all of it.
  bool _refuses(String name) => _newer.contains(name) || _blocked.contains(name);

  String get summary => switch (_state) {
        VaultState.on => 'on ($_kind)',
        VaultState.off => 'off ($_detail)',
        VaultState.locked => 'locked ($_detail)',
        VaultState.starting => 'starting',
      };

  // For data that is written one line at a time and has to reach the disk at
  // once, like the logs. The key is already in memory, so these never wait.
  // sealRecord throws when the vault has no key, so check state == on first.
  Uint8List sealRecord(Uint8List plain) {
    final box = _box;
    if (box == null) throw StateError('the vault has no key');
    return box.seal(plain, _recordLabel);
  }

  Uint8List? openRecord(Uint8List sealed) => _box?.open(sealed, _recordLabel);

  Future<void> init() => _ready ??= _start();

  Future<void> _start() async {
    try {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}${Platform.pathSeparator}vault');
      await dir.create(recursive: true);
      _dir = dir;
      await _openKey(dir);
    } catch (e) {
      _box = null;
      final dir = _dir;
      _state = dir != null && await _hasData(dir) ? VaultState.locked : VaultState.off;
      _detail = 'start failed: $e';
    }
    debugPrint('vault: $summary');
  }

  Future<void> _openKey(Directory dir) async {
    final keyFile = File(_join(dir, 'key.bin'));
    final kind = await _providerKind();
    final provider = _providerId(kind);
    if (provider == _providerNone) {
      _state = await _hasData(dir) ? VaultState.locked : VaultState.off;
      _detail = 'no secure key storage: $_detail';
      return;
    }
    _kind = kind;
    if (await keyFile.exists()) {
      final stored = await _readBytes(keyFile);
      final result = await _unwrapStored(stored, provider);
      final master = result.key;
      if (master != null) {
        await _dropCounters(dir);
        await _adopt(dir, master);
        return;
      }
      if (await _hasData(dir)) {
        // Nothing is moved, deleted or replaced here. The data opens again as
        // soon as the key does, and only the user can decide to start over.
        _state = VaultState.locked;
        _keyGone = result.clear;
        _detail = result.clear
            ? 'the saved key can no longer be opened, nothing was changed: $_detail'
            : 'the saved key could not be opened this time, nothing was changed: $_detail';
        return;
      }
      if (!result.clear) {
        // There is no encrypted data yet, but the key may open again (the key
        // storage was busy, or another version of Xtify wrote the key). It
        // stays where it is and this run keeps its data in plain files, which
        // the next run takes over once the key opens.
        _state = VaultState.off;
        _detail = 'the saved key could not be opened this time, it was kept: $_detail';
        return;
      }
      // No encrypted data, only a key that can never be opened again: there is
      // nothing to lose. Only the key is set aside, plain data of an older run stays.
      await _setAside(dir, keyOnly: true);
    } else if (await _hasData(dir)) {
      // Encrypted data but no key file. A new key would cut the data off for
      // good, so nothing is created and the user decides.
      _state = VaultState.locked;
      _keyGone = true;
      _detail = 'the saved key file is missing, nothing was changed';
      return;
    }
    try {
      final master = VaultCrypto.randomBytes(VaultCrypto.keyLength);
      final blob = await _call<Uint8List>('wrap', master);
      if (blob == null || blob.isEmpty) throw StateError('key storage returned nothing');
      final back = await _call<Uint8List>('unwrap', blob);
      if (back == null || !_same(back, master)) {
        throw StateError('key storage did not return the same key');
      }
      final out = Uint8List(4 + blob.length);
      out.setRange(0, 3, _keyMagic);
      out[3] = provider;
      out.setRange(4, out.length, blob);
      await _writeAtomic(keyFile, out);
      await _adopt(dir, master);
    } catch (e) {
      _box = null;
      _state = await _hasData(dir) ? VaultState.locked : VaultState.off;
      _detail = 'could not create a key: $e';
    }
  }

  Future<void> _adopt(Directory dir, Uint8List master) async {
    final problem = VaultCrypto.selfTest();
    if (problem != null) {
      _box = null;
      _state = await _hasData(dir) ? VaultState.locked : VaultState.off;
      _detail = problem;
      return;
    }
    _box = VaultCrypto(master);
    _state = VaultState.on;
  }

  Future<String> _providerKind() async {
    try {
      return await _call<String>('kind') ?? '';
    } catch (e) {
      _detail = '$e';
      return '';
    }
  }

  static int _providerId(String kind) {
    if (kind == 'android-keystore') return _providerAndroid;
    if (kind == 'windows-dpapi') return _providerWindows;
    return _providerNone;
  }

  Future<T?> _call<T>(String method, [Object? arguments]) =>
      _channel.invokeMethod<T>(method, arguments).timeout(_callTimeout);

  // [clear] says whether the key storage gave a clear verdict that the saved
  // key can never be opened again (it lost the key, or the saved key is
  // damaged). Anything else, like a busy key storage or no answer in time, may
  // pass by itself and is retried at the next start.
  Future<({Uint8List? key, bool clear})> _unwrapStored(Uint8List stored, int provider) async {
    // A key file of another version or another key storage is not damaged, so
    // it never counts as a clear verdict and Start fresh is not offered for it.
    final ours = stored.length >= 4 && stored[0] == _keyMagic[0] && stored[1] == _keyMagic[1];
    if (ours && stored[2] != _keyMagic[2]) {
      _detail = 'the saved key was written by a newer version of Xtify';
      return (key: null, clear: false);
    }
    if (ours && stored[3] != provider) {
      _detail = 'the saved key belongs to a different key storage';
      return (key: null, clear: false);
    }
    if (!ours || stored.length < 5) {
      _detail = 'the saved key is not readable';
      return (key: null, clear: true);
    }
    final blob = Uint8List.fromList(stored.sublist(4));
    for (final wait in const [0, 250, 750]) {
      if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
      try {
        final key = await _call<Uint8List>('unwrap', blob);
        if (key != null && key.length == VaultCrypto.keyLength) return (key: key, clear: false);
        _detail = 'key storage gave a key of the wrong size';
        return (key: null, clear: true);
      } on PlatformException catch (e) {
        _detail = '${e.code}: ${e.message}';
        if (_verdictCodes.contains(e.code)) return (key: null, clear: true);
      } on TimeoutException {
        _detail = 'the key storage did not answer in time';
        break;
      } catch (e) {
        _detail = '$e';
      }
    }
    return (key: null, clear: false);
  }

  // Version 3.5.0 counted failed starts in these two files. They are not used any more.
  Future<void> _dropCounters(Directory dir) async {
    for (final name in const ['key.fail', 'key.slow']) {
      await _remove(File(_join(dir, name)));
    }
  }

  // Only for a locked vault whose key is gone, and only after the user has
  // confirmed. Nothing is deleted: every saved file moves into a lost-<time>
  // folder, and the next start begins with a new key.
  Future<bool> startFresh() async {
    await init();
    final dir = _dir;
    if (dir == null || !canStartFresh) return false;
    try {
      await _setAside(dir);
      _keyGone = false;
      _startedFresh = true;
      return true;
    } catch (e) {
      debugPrint('vault: could not start fresh: $e');
      return false;
    }
  }

  Future<void> _setAside(Directory dir, {bool keyOnly = false}) async {
    final lost = Directory(_join(dir, 'lost-${DateTime.now().millisecondsSinceEpoch}'));
    await lost.create(recursive: true);
    final files = await dir.list(followLinks: false).where((e) => e is File).toList();
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      if (keyOnly && !name.startsWith('key.')) continue;
      try {
        await file.rename(_join(lost, name));
      } catch (e) {
        debugPrint('vault: could not move $name aside: $e');
      }
    }
  }

  // When the folder cannot be listed, it is not known that nothing is in it, so
  // this says yes: a folder that might hold data is never treated as empty.
  Future<bool> _hasData(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.uri.pathSegments.last.contains('.xv')) return true;
      }
    } catch (_) {
      return true;
    }
    return false;
  }

  Future<Uint8List?> read(String name) async {
    await init();
    final dir = _dir;
    if (dir == null || !canWrite) return null;
    _check(name);
    return _recover(dir, name);
  }

  Future<String?> readText(String name) async {
    final bytes = await read(name);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<bool> write(
    String name,
    Uint8List bytes, {
    bool backup = true,
    bool durable = true,
  }) async {
    await init();
    final dir = _dir;
    if (dir == null || !canWrite) return false;
    _check(name);
    if (_refuses(name)) return false;
    return _queue<bool>(
      name,
      () => _store(dir, name, bytes, backup: backup, durable: durable),
    );
  }

  Future<bool> writeText(
    String name,
    String text, {
    bool backup = true,
    bool durable = true,
  }) =>
      write(name, Uint8List.fromList(utf8.encode(text)), backup: backup, durable: durable);

  Future<bool> exists(String name) async {
    await init();
    final dir = _dir;
    if (dir == null || !canWrite) return false;
    _check(name);
    for (final ext in const ['xv', 'xp']) {
      for (final tail in const ['', '.tmp', '.bak']) {
        if (await File(_join(dir, '$name.$ext$tail')).exists()) return true;
      }
    }
    return false;
  }

  Future<void> delete(String name) async {
    await init();
    final dir = _dir;
    if (dir == null || !canWrite) return;
    _check(name);
    if (_refuses(name)) return;
    await _queue<void>(name, () async {
      // An item this run has not read could have been written by a newer
      // version, and that one is never deleted.
      if (_box != null &&
          !_verified.contains(name) &&
          await _holdsOtherVersion(File(_join(dir, '$name.xv')))) {
        _keepNewer(name);
        return;
      }
      for (final tail in const ['', '.tmp', '.bak', '.broken']) {
        await _remove(File(_join(dir, '$name.xv$tail')));
        await wipe(File(_join(dir, '$name.xp$tail')));
      }
    });
  }

  Future<List<String>> names(String prefix) async {
    await init();
    final dir = _dir;
    if (dir == null || !canWrite) return const <String>[];
    final found = <String>{};
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final file = entity.uri.pathSegments.last;
        for (final ext in const ['.xv', '.xv.bak', '.xv.tmp', '.xp', '.xp.bak']) {
          if (!file.endsWith(ext)) continue;
          final name = file.substring(0, file.length - ext.length);
          if (name.startsWith(prefix)) found.add(name);
        }
      }
    } catch (e) {
      debugPrint('vault: could not list the saved items: $e');
    }
    return found.toList();
  }

  // Reads a saved item. [legacy] is the plain file that older versions of
  // Xtify kept in its place. It is never just deleted: when the item does not
  // exist yet the plain file becomes the item, and when it does (an older
  // version was used after an update, then the new one again) [merge] joins
  // the two so the changes of both survive. A copy that cannot be merged is
  // kept under a name of its own before the plain file is wiped.
  Future<String?> readTextOrMove(
    String name,
    File legacy, {
    bool Function(String text)? isValid,
    String Function(String current, String older)? merge,
  }) async {
    var text = await readText(name);
    for (final file in [legacy, File('${legacy.path}.tmp')]) {
      try {
        if (!await file.exists()) continue;
        text = await _takeOlder(name, file, text, isValid, merge);
      } catch (e) {
        // The plain file stays where it is and is taken over at the next start.
        debugPrint('vault: could not take over ${file.uri.pathSegments.last}: $e');
      }
    }
    return text;
  }

  Future<String?> _takeOlder(
    String name,
    File file,
    String? current,
    bool Function(String text)? isValid,
    String Function(String current, String older)? merge,
  ) async {
    final bytes = await _readBytes(file);
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      if (canWrite && await write(_sideName(name, 'unreadable', bytes), bytes)) {
        await wipe(file);
      }
      return current;
    }
    final valid = isValid == null || isValid(text);
    if (!canWrite) return current ?? (valid ? text : null);
    if (!valid) {
      if (await write(_sideName(name, 'unreadable', bytes), bytes)) await wipe(file);
      return current;
    }
    if (current == null) {
      if (await writeText(name, text) && await readText(name) == text) await wipe(file);
      return text;
    }
    if (current == text) {
      await wipe(file);
      return current;
    }
    String? merged;
    if (merge != null) {
      try {
        merged = merge(current, text);
      } catch (e) {
        debugPrint('vault: could not merge the older copy of $name: $e');
      }
    }
    if (merged == null) {
      if (await write(_sideName(name, 'older', bytes), bytes)) await wipe(file);
      return current;
    }
    if (merged == current) {
      await wipe(file);
      return current;
    }
    if (await writeText(name, merged) && await readText(name) == merged) await wipe(file);
    return merged;
  }

  static bool isJsonList(String text) {
    try {
      return jsonDecode(text) is List<dynamic>;
    } catch (_) {
      return false;
    }
  }

  static Future<void> wipe(File file) async {
    try {
      if (!await file.exists()) return;
      final length = await file.length();
      if (length > 0 && length <= _wipeUpTo) {
        await file.writeAsBytes(Uint8List(length), flush: true);
      }
      await file.delete();
    } catch (e) {
      debugPrint('vault: could not remove ${file.uri.pathSegments.last}: $e');
    }
  }

  Future<Uint8List?> _recover(Directory dir, String name) async {
    try {
      final ext = _box != null ? 'xv' : 'xp';
      final main = File(_join(dir, '$name.$ext'));
      final present = await main.exists();
      if (present) {
        final raw = await _readBytes(main);
        if (_box != null && VaultCrypto.isOtherVersion(raw)) {
          // Not damaged, just written by a newer Xtify. Nothing is renamed or
          // replaced, and no older copy is shown in its place.
          _keepNewer(name);
          return null;
        }
        final value = await _decode(raw, name);
        if (value != null) {
          _verified.add(name);
          return value;
        }
        await _setBroken(main);
      }
      final spare = _box != null ? ['$name.$ext.tmp', '$name.$ext.bak'] : ['$name.$ext.bak'];
      for (final file in spare) {
        final copy = File(_join(dir, file));
        if (!await copy.exists()) continue;
        final value = await _decode(await _readBytes(copy), name);
        if (value == null) continue;
        await _queue<bool>(
          name,
          () => _store(dir, name, value, backup: false, durable: true),
        );
        return value;
      }
      if (_box != null) return await _adoptPlain(dir, name);
    } catch (e) {
      // Something is there but it could not be read. Treating that as nothing
      // saved would let the next save replace the real data with an empty
      // list, so this item is left alone until the next start.
      _hold(name, e);
    }
    return null;
  }

  void _hold(String name, Object error) {
    debugPrint('vault: could not read $name: $error');
    if (!_blocked.add(name)) return;
    _note(
      'blocked:$name',
      'Xtify could not read your ${_label(name)} this time. It is left as it is and '
      'changes to it are not saved. Close Xtify and open it again to retry. '
      'Nothing was deleted.',
    );
  }

  // A read can fail for a moment, for example while a virus scanner has the file open.
  static Future<Uint8List> _readBytes(File file) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await file.readAsBytes();
      } on FileSystemException {
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
  }

  // The name of a side copy. It comes from the content, so the same copy is
  // never saved twice and a different one never replaces it.
  static String _sideName(String name, String kind, Uint8List bytes) {
    var hash = 0x811C9DC5;
    for (final b in bytes) {
      hash = ((hash ^ b) * 0x01000193) & 0xFFFFFFFF;
    }
    return '$name-$kind-${bytes.length}-${hash.toRadixString(16).padLeft(8, '0')}';
  }

  Future<Uint8List?> _adoptPlain(Directory dir, String name) async {
    final plain = File(_join(dir, '$name.xp'));
    if (!await plain.exists()) return null;
    final bytes = await _readBytes(plain);
    final saved = await _queue<bool>(
      name,
      () => _store(dir, name, bytes, backup: false, durable: true),
    );
    if (saved) {
      for (final tail in const ['', '.tmp', '.bak']) {
        await wipe(File(_join(dir, '$name.xp$tail')));
      }
    }
    return bytes;
  }

  Future<Uint8List?> _decode(Uint8List raw, String name) async {
    final box = _box;
    if (box == null) return raw;
    return _openSealed(box, raw, name);
  }

  static Future<Uint8List?> _openSealed(VaultCrypto box, Uint8List raw, String name) async {
    if (raw.length >= _backgroundFrom) {
      try {
        return await _openInBackground(box, raw, name);
      } catch (e) {
        debugPrint('vault: decrypting in the background failed, doing it here: $e');
      }
    }
    return box.open(raw, name);
  }

  static Future<Uint8List> _sealPlain(VaultCrypto box, Uint8List plain, String name) async {
    if (plain.length >= _backgroundFrom) {
      try {
        return await _sealInBackground(box, plain, name);
      } catch (e) {
        debugPrint('vault: encrypting in the background failed, doing it here: $e');
      }
    }
    return box.seal(plain, name);
  }

  static Future<Uint8List?> _openInBackground(VaultCrypto box, Uint8List raw, String name) =>
      Isolate.run<Uint8List?>(() => box.open(raw, name));

  static Future<Uint8List> _sealInBackground(VaultCrypto box, Uint8List plain, String name) =>
      Isolate.run<Uint8List>(() => box.seal(plain, name));

  Future<bool> _store(
    Directory dir,
    String name,
    Uint8List bytes, {
    required bool backup,
    required bool durable,
  }) async {
    try {
      if (_blocked.contains(name)) return false;
      final box = _box;
      final ext = box != null ? 'xv' : 'xp';
      final main = File(_join(dir, '$name.$ext'));
      final tmp = File(_join(dir, '$name.$ext.tmp'));
      if (box != null && !_verified.contains(name) && await _holdsOtherVersion(main)) {
        _keepNewer(name);
        return false;
      }
      await tmp.writeAsBytes(box != null ? await _sealPlain(box, bytes, name) : bytes,
          flush: durable);
      if (box != null && durable) {
        final check = await _openSealed(box, await tmp.readAsBytes(), name);
        if (check == null || check.length != bytes.length) {
          await _remove(tmp);
          return false;
        }
      }
      if (backup && await main.exists()) {
        try {
          await main.copy(_join(dir, '$name.$ext.bak'));
        } catch (_) {}
      }
      await tmp.rename(main.path);
      _verified.add(name);
      return true;
    } catch (e) {
      debugPrint('vault: could not save $name: $e');
      return false;
    }
  }

  static Future<bool> _holdsOtherVersion(File file) async {
    try {
      if (!await file.exists()) return false;
      final reader = await file.open();
      try {
        return VaultCrypto.isOtherVersion(await reader.read(4));
      } finally {
        await reader.close();
      }
    } catch (_) {
      return false;
    }
  }

  void _keepNewer(String name) {
    if (!_newer.add(name)) return;
    _note(
      'newer:$name',
      'Saved data (${_label(name)}) was written by a newer version of Xtify. '
      'It is left as it is, and changes to it are not saved until you update.',
    );
  }

  // For a store that could not make sense of what it read. The saved data is left as it is.
  void noteUnreadable(String what) => _note(
        'unreadable:$what',
        'Xtify could not read your $what. The saved data is left as it is and '
        'changes are not saved. Nothing was deleted.',
      );

  void _note(String key, String text) {
    if (_notes[key] == text) return;
    _notes[key] = text;
    notices.value = List<String>.unmodifiable(_notes.values);
  }

  static String _label(String name) {
    if (name.startsWith('p.')) return 'settings and history';
    return switch (name) {
      'playlists' => 'playlists',
      'downloads' => 'downloads list',
      'import-reports' => 'import reports',
      'yt-cookies' => 'YouTube sign-in',
      _ => name,
    };
  }

  // Only after the user has confirmed. Moves what a newer version of Xtify
  // wrote into a lost-<time> folder (nothing is deleted) so that this version
  // can save its own data in its place.
  Future<bool> setAsideNewer() async {
    final dir = _dir;
    if (dir == null || _newer.isEmpty) return false;
    try {
      final lost = Directory(_join(dir, 'lost-${DateTime.now().millisecondsSinceEpoch}'));
      await lost.create(recursive: true);
      for (final name in _newer.toList()) {
        for (final tail in const ['', '.tmp', '.bak', '.broken']) {
          final file = File(_join(dir, '$name.xv$tail'));
          if (await file.exists()) await file.rename(_join(lost, '$name.xv$tail'));
        }
        _newer.remove(name);
        _verified.remove(name);
        _notes.remove('newer:$name');
      }
      notices.value = List<String>.unmodifiable(_notes.values);
      return true;
    } catch (e) {
      debugPrint('vault: could not set the newer data aside: $e');
      return false;
    }
  }

  Future<T> _queue<T>(String name, Future<T> Function() job) {
    final previous = _tails[name] ?? Future<void>.value();
    final run = previous.then((_) => job());
    final tail = run.then<void>((_) {}, onError: (Object _) {});
    _tails[name] = tail;
    tail.whenComplete(() {
      if (identical(_tails[name], tail)) _tails.remove(name);
    });
    return run;
  }

  Future<void> _setBroken(File file) async {
    try {
      await file.rename('${file.path}.broken');
      debugPrint('vault: ${file.uri.pathSegments.last} could not be read, kept as a .broken copy');
    } catch (_) {}
  }

  Future<void> _writeAtomic(File target, Uint8List bytes) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  }

  Future<void> _remove(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _check(String name) {
    if (!_safeName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'is not a valid vault name');
    }
  }

  static String _join(Directory dir, String file) =>
      '${dir.path}${Platform.pathSeparator}$file';

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
