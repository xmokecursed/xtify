import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'vault_crypto.dart';

typedef SealRecord = Uint8List Function(Uint8List plain);
typedef OpenRecord = Uint8List? Function(Uint8List sealed);

class LogSession {
  final int number;
  final String text;
  final int skipped;

  const LogSession(this.number, this.text, {this.skipped = 0});
}

class _Entry {
  final int number;
  final File file;
  final bool sealed;

  const _Entry(this.number, this.file, this.sealed);
}

class _Span {
  final int start;
  final int end;

  const _Span(this.start, this.end);
}

// One log file per run of the app. Without a key a file is plain text with one
// line per row (session-N.log). With a key every line is sealed on its own and
// written at once as a record: two bytes with the length of the sealed line,
// then the sealed line (session-N.xlog). A record that a crash cut short is
// skipped when the file is read, and nothing in the file can be read without
// the key.
class LogStore {
  LogStore(
    this.directory, {
    this.seal,
    this.unseal,
    this.keepSessions = 6,
    int? maxBytes,
    int? trimBytes,
  })  : _maxBytes = maxBytes ?? (seal == null ? 160 * 1024 : 256 * 1024),
        _trimBytes = trimBytes ?? (seal == null ? 96 * 1024 : 160 * 1024);

  final Directory directory;
  final SealRecord? seal;
  final OpenRecord? unseal;
  final int keepSessions;
  final int _maxBytes;
  final int _trimBytes;

  static final RegExp _name = RegExp(r'^session-(\d+)\.(log|xlog)$');
  static final RegExp _leftover = RegExp(r'^session-\d+\.xlog\.tmp$');
  static const int _recordHead = 2;
  static const int _longestLine = 8000;
  static const int _wipeUpTo = 8 * 1024 * 1024;
  static const String _cut = '(older lines were removed to keep this log small)';

  File? _file;
  RandomAccessFile? _out;
  String _header = '';
  int _size = 0;
  int _number = 0;

  int get number => _number;

  bool get encrypted => seal != null;

  // After going back to 3.5.0 and forward again, a plain log can carry the
  // number of an encrypted one. It moves to a number of its own, so that
  // encryptOld converts it like any other old log instead of treating it as a
  // duplicate to wipe.
  void _renumberClashes() {
    try {
      final all = _all();
      final taken = <int>{
        for (final entry in all)
          if (entry.sealed) entry.number,
      };
      var top = all.isEmpty ? 0 : all.last.number;
      for (final entry in all) {
        if (entry.sealed || !taken.contains(entry.number)) continue;
        top++;
        entry.file.renameSync('${directory.path}${Platform.pathSeparator}session-$top.log');
      }
    } catch (_) {}
  }

  void open(String info) {
    directory.createSync(recursive: true);
    if (encrypted) _renumberClashes();
    final all = _all();
    final numbers = <int>[];
    for (final entry in all) {
      if (numbers.isEmpty || numbers.last != entry.number) numbers.add(entry.number);
    }
    final next = numbers.isEmpty ? 1 : numbers.last + 1;
    final excess = numbers.length - (keepSessions - 1);
    if (excess > 0) {
      final drop = numbers.take(excess).toSet();
      for (final entry in all) {
        if (!drop.contains(entry.number)) continue;
        try {
          entry.file.deleteSync();
        } catch (_) {}
      }
    }
    _number = next;
    _header = '=== session $next | $info ===';
    final file = File(
      '${directory.path}${Platform.pathSeparator}session-$next.${encrypted ? 'xlog' : 'log'}',
    );
    final out = file.openSync(mode: FileMode.append);
    final bytes = _encode(_header);
    out.writeFromSync(bytes);
    _size = bytes.length;
    _file = file;
    _out = out;
  }

  void add(String line) {
    final out = _out;
    if (out == null) return;
    try {
      final bytes = _encode(line);
      out.writeFromSync(bytes);
      _size += bytes.length;
      if (_size > _maxBytes) _trim();
    } catch (_) {
      try {
        out.truncateSync(_size);
        out.setPositionSync(_size);
      } catch (_) {}
    }
  }

  List<LogSession> sessions({int last = 3, int tail = 30000}) {
    final found = <LogSession>[];
    try {
      final entries = _entries();
      final from = entries.length > last ? entries.length - last : 0;
      for (var i = from; i < entries.length; i++) {
        try {
          final entry = entries[i];
          final session = entry.sealed ? _readSealed(entry, tail) : _readPlain(entry);
          if (session != null) found.add(session);
        } catch (_) {}
      }
    } catch (_) {}
    return found;
  }

  // Turns the plain logs of older versions into encrypted ones, one file at a
  // time, and wipes the plain copy once the encrypted one is in place.
  Future<void> encryptOld() async {
    if (seal == null) return;
    try {
      final all = _all();
      final done = <int>{
        for (final entry in all)
          if (entry.sealed) entry.number,
      };
      for (final entry in all) {
        if (entry.sealed || entry.number == _number) continue;
        try {
          if (!done.contains(entry.number)) _convert(entry);
          _wipe(entry.file);
        } catch (_) {}
        await Future<void>.delayed(Duration.zero);
      }
      for (final entity in directory.listSync()) {
        if (entity is File && _leftover.hasMatch(entity.uri.pathSegments.last)) {
          _wipe(entity);
        }
      }
    } catch (_) {}
  }

  void _convert(_Entry entry) {
    final text = utf8.decode(entry.file.readAsBytesSync(), allowMalformed: true);
    final out = BytesBuilder(copy: false);
    for (final line in const LineSplitter().convert(text)) {
      if (line.isNotEmpty) out.add(_encode(line));
    }
    final bytes = out.takeBytes();
    final target = File(
      '${directory.path}${Platform.pathSeparator}session-${entry.number}.xlog',
    );
    final tmp = File('${target.path}.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    if (tmp.lengthSync() != bytes.length) {
      _wipe(tmp);
      throw const FileSystemException('the encrypted log was not written completely');
    }
    tmp.renameSync(target.path);
  }

  LogSession _readPlain(_Entry entry) {
    final text = utf8.decode(entry.file.readAsBytesSync(), allowMalformed: true);
    return LogSession(entry.number, text);
  }

  LogSession? _readSealed(_Entry entry, int tail) {
    final unseal = this.unseal;
    if (unseal == null) return null;
    final bytes = entry.file.readAsBytesSync();
    final spans = _spans(bytes);
    if (spans.isEmpty) return null;
    String? read(_Span span) {
      final plain = unseal(Uint8List.sublistView(bytes, span.start + _recordHead, span.end));
      return plain == null ? null : utf8.decode(plain, allowMalformed: true);
    }

    final head = read(spans.first);
    final lines = <String>[];
    var used = 0;
    var skipped = 0;
    for (var i = spans.length - 1; i > 0; i--) {
      final text = read(spans[i]);
      if (text == null) continue;
      final cost = text.length + 1;
      if (used + cost > tail) {
        skipped = i;
        break;
      }
      used += cost;
      lines.add(text);
    }
    if (head == null && lines.isEmpty) return null;
    return LogSession(
      entry.number,
      [if (head != null) head, ...lines.reversed].join('\n'),
      skipped: skipped,
    );
  }

  Uint8List _encode(String line) {
    final seal = this.seal;
    if (seal == null) return Uint8List.fromList([...utf8.encode(line), 10]);
    final text = line.length > _longestLine ? line.substring(0, _longestLine) : line;
    final blob = seal(Uint8List.fromList(utf8.encode(text)));
    final out = Uint8List(_recordHead + blob.length);
    out[0] = (blob.length >> 8) & 0xFF;
    out[1] = blob.length & 0xFF;
    out.setRange(_recordHead, out.length, blob);
    return out;
  }

  static List<_Span> _spans(Uint8List bytes) {
    final out = <_Span>[];
    var at = 0;
    while (at + _recordHead <= bytes.length) {
      final length = (bytes[at] << 8) | bytes[at + 1];
      final end = at + _recordHead + length;
      if (length < VaultCrypto.overhead || end > bytes.length) break;
      out.add(_Span(at, end));
      at = end;
    }
    return out;
  }

  void _trim() {
    final file = _file;
    final out = _out;
    if (file == null || out == null) return;
    final bytes = file.readAsBytesSync();
    _size = bytes.length;
    final kept = encrypted ? _keepSealed(bytes) : _keepPlain(bytes);
    if (kept == null) return;
    _out = null;
    out.closeSync();
    try {
      file.writeAsBytesSync(kept);
      _size = kept.length;
    } finally {
      _out = file.openSync(mode: FileMode.append);
    }
  }

  Uint8List? _keepPlain(Uint8List bytes) {
    var cut = bytes.length - _trimBytes;
    if (cut <= 0) return null;
    final newline = bytes.indexOf(10, cut);
    if (newline != -1) cut = newline + 1;
    final out = BytesBuilder(copy: false)
      ..add(_encode(_header))
      ..add(_encode(_cut))
      ..add(Uint8List.sublistView(bytes, cut));
    return out.takeBytes();
  }

  Uint8List? _keepSealed(Uint8List bytes) {
    final spans = _spans(bytes);
    if (spans.length < 3) return null;
    final from = bytes.length - _trimBytes;
    var first = -1;
    for (var i = 1; i < spans.length; i++) {
      if (spans[i].start >= from) {
        first = i;
        break;
      }
    }
    if (first == -1) return null;
    final out = BytesBuilder(copy: false)
      ..add(_encode(_header))
      ..add(_encode(_cut))
      ..add(Uint8List.sublistView(bytes, spans[first].start, spans.last.end));
    return out.takeBytes();
  }

  static void _wipe(File file) {
    try {
      final length = file.lengthSync();
      if (length > 0 && length <= _wipeUpTo) {
        file.writeAsBytesSync(Uint8List(length), flush: true);
      }
    } catch (_) {}
    try {
      file.deleteSync();
    } catch (_) {}
  }

  List<_Entry> _all() {
    final found = <_Entry>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final match = _name.firstMatch(entity.uri.pathSegments.last);
      if (match == null) continue;
      final number = int.tryParse(match.group(1)!);
      if (number == null) continue;
      found.add(_Entry(number, entity, match.group(2) == 'xlog'));
    }
    found.sort((a, b) {
      final order = a.number.compareTo(b.number);
      if (order != 0) return order;
      if (a.sealed == b.sealed) return 0;
      return a.sealed ? -1 : 1;
    });
    return found;
  }

  List<_Entry> _entries() {
    final out = <_Entry>[];
    for (final entry in _all()) {
      if (out.isNotEmpty && out.last.number == entry.number) continue;
      out.add(entry);
    }
    return out;
  }
}
