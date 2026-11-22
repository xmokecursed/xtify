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
  static const int _giveUpAfter = 3;
  static const int _giveUpAfterSlow = 12;
  static const Duration _callTimeout = Duration(seconds: 8);
  static const Set<String> _verdictCodes = {'key_missing', 'bad_blob', 'key_mismatch', 'dpapi'};
  static const int _backgroundFrom = 192 * 1024;
  static const int _wipeUpTo = 8 * 1024 * 1024;
  static final RegExp _safeName = RegExp(r'^[A-Za-z0-9._-]{1,120}$');

  VaultState _state = VaultState.starting;
  String _detail = '';
  String _kind = '';
  Directory? _dir;
  VaultCrypto? _box;
  Future<void>? _ready;
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  VaultState get state => _state;

  bool get canWrite => _state == VaultState.on || _state == VaultState.off;

  String get summary => switch (_state) {
        VaultState.on => 'on ($_kind)',
        VaultState.off => 'off ($_detail)',
        VaultState.locked => 'locked ($_detail)',
        VaultState.starting => 'starting',
      };

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
    final failFile = File(_join(dir, 'key.fail'));
    final slowFile = File(_join(dir, 'key.slow'));
    final kind = await _providerKind();
    final provider = _providerId(kind);
    if (provider == _providerNone) {
      _state = await _hasData(dir) ? VaultState.locked : VaultState.off;
      _detail = 'no secure key storage: $_detail';
      return;
    }
    _kind = kind;
    if (await keyFile.exists()) {
      final stored = await keyFile.readAsBytes();
      final result = await _unwrapStored(stored, provider);
      final master = result.key;
      if (master != null) {
        await _remove(failFile);
        await _remove(slowFile);
        await _adopt(dir, master);
        return;
      }
      final failures = await _countFailure(result.clear ? failFile : slowFile);
      final limit = result.clear ? _giveUpAfter : _giveUpAfterSlow;
      if (failures < limit) {
        _state = VaultState.locked;
        _detail = 'could not unlock the saved key, attempt $failures of $limit: $_detail';
        return;
      }
      debugPrint('vault: the saved key stayed locked, starting a new vault');
      await _setAside(dir);
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
    final head = stored.length >= 5 &&
        stored[0] == _keyMagic[0] &&
        stored[1] == _keyMagic[1] &&
        stored[2] == _keyMagic[2] &&
        stored[3] == provider;
    if (!head) {
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

  Future<int> _countFailure(File file) async {
    var count = 0;
    try {
      if (await file.exists()) count = int.tryParse((await file.readAsString()).trim()) ?? 0;
    } catch (_) {}
    count++;
    try {
      await file.writeAsString('$count', flush: true);
    } catch (_) {}
    return count;
  }

  Future<void> _setAside(Directory dir) async {
    final lost = Directory(_join(dir, 'lost-${DateTime.now().millisecondsSinceEpoch}'));
    await lost.create(recursive: true);
    final files = await dir.list(followLinks: false).where((e) => e is File).toList();
    for (final file in files) {
      final name = file.uri.pathSegments.last;
      try {
        await file.rename(_join(lost, name));
      } catch (e) {
        debugPrint('vault: could not move $name aside: $e');
      }
    }
  }

  Future<bool> _hasData(Directory dir) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.contains('.xv')) return true;
      }
    } catch (_) {}
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
    await _queue<void>(name, () async {
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

  Future<String?> readTextOrMove(
    String name,
    File legacy, {
    bool Function(String text)? isValid,
  }) async {
    final stored = await readText(name);
    if (stored != null) {
      await _dropLegacy(legacy);
      return stored;
    }
    if (!await legacy.exists()) return null;
    final bytes = await legacy.readAsBytes();
    String text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      if (canWrite && await write('$name-unreadable', bytes)) await _dropLegacy(legacy);
      return null;
    }
    final valid = isValid == null || isValid(text);
    if (!canWrite) return valid ? text : null;
    if (!valid) {
      if (await writeText('$name-unreadable', text)) await _dropLegacy(legacy);
      return null;
    }
    if (await writeText(name, text) && await readText(name) == text) {
      await _dropLegacy(legacy);
    }
    return text;
  }

  Future<void> _dropLegacy(File legacy) async {
    await wipe(legacy);
    await wipe(File('${legacy.path}.tmp'));
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
        final value = await _decode(await main.readAsBytes(), name);
        if (value != null) return value;
        await _setBroken(main);
      }
      final spare = _box != null ? ['$name.$ext.tmp', '$name.$ext.bak'] : ['$name.$ext.bak'];
      for (final file in spare) {
        final copy = File(_join(dir, file));
        if (!await copy.exists()) continue;
        final value = await _decode(await copy.readAsBytes(), name);
        if (value == null) continue;
        await _queue<bool>(
          name,
          () => _store(dir, name, value, backup: false, durable: true),
        );
        return value;
      }
      if (_box != null) return await _adoptPlain(dir, name);
    } catch (e) {
      debugPrint('vault: could not read $name: $e');
    }
    return null;
  }

  Future<Uint8List?> _adoptPlain(Directory dir, String name) async {
    final plain = File(_join(dir, '$name.xp'));
    if (!await plain.exists()) return null;
    final bytes = await plain.readAsBytes();
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
      final box = _box;
      final ext = box != null ? 'xv' : 'xp';
      final main = File(_join(dir, '$name.$ext'));
      final tmp = File(_join(dir, '$name.$ext.tmp'));
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
      return true;
    } catch (e) {
      debugPrint('vault: could not save $name: $e');
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
