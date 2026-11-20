import 'dart:convert';
import 'dart:io';

class LogSession {
  final int number;
  final String text;

  const LogSession(this.number, this.text);
}

class _Entry {
  final int number;
  final File file;

  const _Entry(this.number, this.file);
}

class LogStore {
  LogStore(
    this.directory, {
    this.keepSessions = 6,
    this.maxBytes = 160 * 1024,
    this.trimBytes = 96 * 1024,
  });

  final Directory directory;
  final int keepSessions;
  final int maxBytes;
  final int trimBytes;

  static final RegExp _name = RegExp(r'^session-(\d+)\.log$');

  File? _file;
  RandomAccessFile? _out;
  String _header = '';
  int _size = 0;
  int _number = 0;

  int get number => _number;

  void open(String info) {
    directory.createSync(recursive: true);
    final existing = _entries();
    final next = existing.isEmpty ? 1 : existing.last.number + 1;
    final excess = existing.length - (keepSessions - 1);
    for (var i = 0; i < excess; i++) {
      try {
        existing[i].file.deleteSync();
      } catch (_) {}
    }
    _number = next;
    _header = '=== session $next | $info ===';
    final file = File('${directory.path}${Platform.pathSeparator}session-$next.log');
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
      if (_size > maxBytes) _trim();
    } catch (_) {}
  }

  List<LogSession> sessions() {
    final found = <LogSession>[];
    try {
      for (final entry in _entries()) {
        try {
          final text = utf8.decode(entry.file.readAsBytesSync(), allowMalformed: true);
          found.add(LogSession(entry.number, text));
        } catch (_) {}
      }
    } catch (_) {}
    return found;
  }

  static List<int> _encode(String line) => [...utf8.encode(line), 10];

  void _trim() {
    final file = _file;
    final out = _out;
    if (file == null || out == null) return;
    final bytes = file.readAsBytesSync();
    _size = bytes.length;
    var cut = bytes.length - trimBytes;
    if (cut <= 0) return;
    final newline = bytes.indexOf(10, cut);
    if (newline != -1) cut = newline + 1;
    final kept = <int>[
      ..._encode(_header),
      ..._encode('(older lines were removed to keep this log small)'),
      ...bytes.sublist(cut),
    ];
    _out = null;
    out.closeSync();
    try {
      file.writeAsBytesSync(kept);
      _size = kept.length;
    } finally {
      _out = file.openSync(mode: FileMode.append);
    }
  }

  List<_Entry> _entries() {
    final found = <_Entry>[];
    for (final entity in directory.listSync()) {
      if (entity is! File) continue;
      final match = _name.firstMatch(entity.uri.pathSegments.last);
      final number = match == null ? null : int.tryParse(match.group(1)!);
      if (number != null) found.add(_Entry(number, entity));
    }
    found.sort((a, b) => a.number.compareTo(b.number));
    return found;
  }
}
