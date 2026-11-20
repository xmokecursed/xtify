import 'dart:async';
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
    this.flushDelay = const Duration(milliseconds: 300),
  });

  final Directory directory;
  final int keepSessions;
  final int maxBytes;
  final int trimBytes;
  final Duration flushDelay;

  static final RegExp _name = RegExp(r'^session-(\d+)\.log$');

  final StringBuffer _pending = StringBuffer();
  Timer? _timer;
  File? _file;
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
    final first = StringBuffer()..writeln(_header);
    final bytes = utf8.encode(first.toString());
    file.writeAsBytesSync(bytes);
    _size = bytes.length;
    _file = file;
  }

  void add(String line) {
    if (_file == null) return;
    _pending.writeln(line);
    _timer ??= Timer(flushDelay, flush);
  }

  void flush() {
    _timer?.cancel();
    _timer = null;
    final file = _file;
    if (file == null || _pending.isEmpty) return;
    final bytes = utf8.encode(_pending.toString());
    _pending.clear();
    try {
      file.writeAsBytesSync(bytes, mode: FileMode.append);
      _size += bytes.length;
      if (_size > maxBytes) _trim(file);
    } catch (_) {}
  }

  List<LogSession> sessions() {
    flush();
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

  void _trim(File file) {
    final bytes = file.readAsBytesSync();
    var cut = bytes.length - trimBytes;
    if (cut <= 0) return;
    final newline = bytes.indexOf(10, cut);
    if (newline != -1) cut = newline + 1;
    final head = StringBuffer()
      ..writeln(_header)
      ..writeln('(older lines were removed to keep this log small)');
    final kept = <int>[...utf8.encode(head.toString()), ...bytes.sublist(cut)];
    file.writeAsBytesSync(kept);
    _size = kept.length;
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
