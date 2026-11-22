import 'dart:collection';
import 'dart:convert' show LineSplitter;
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:path_provider/path_provider.dart';
import 'android_records.dart';
import 'connectivity_service.dart';
import 'cookie_service.dart';
import 'download_service.dart';
import 'history_service.dart';
import 'audio_service.dart';
import 'log_store.dart';
import 'vault.dart';

class DebugLog {
  DebugLog._();
  static const int _max = 400;
  static const List<int> _budgets = [27000, 19000, 5000];
  static const int _recordsLimit = 12000;
  static final Queue<String> _lines = Queue<String>();
  static LogStore? _store;
  static String _version = '?';
  static String? _last;
  static int _repeats = 0;

  static Future<void> startSaving() async {
    try {
      _version = await _readVersion();
      final base = await getApplicationSupportDirectory();
      final store = LogStore(Directory('${base.path}${Platform.pathSeparator}logs'));
      final system = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'
          .replaceAll(RegExp(r'\s+'), ' ');
      store.open('Xtify $_version | $system | pid $pid | '
          'started ${DateTime.now().toIso8601String()}');
      for (final line in _lines) {
        store.add(line);
      }
      _store = store;
      WidgetsBinding.instance.addObserver(_Watcher());
      add('log: saved on this device, session ${store.number}');
    } catch (e) {
      debugPrint('log: could not save to disk: $e');
    }
  }

  static Future<String> _readVersion() async {
    try {
      final text = await rootBundle.loadString('pubspec.yaml');
      final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
      return m?.group(1) ?? '?';
    } catch (_) {
      return '?';
    }
  }

  static String _memory() {
    try {
      return '${(ProcessInfo.currentRss / (1024 * 1024)).round()} MB';
    } catch (_) {
      return '?';
    }
  }

  static void flush() {
    _closeRepeats();
    _last = null;
  }

  static void install() {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) add(message);
      original(message == null ? null : _color(message), wrapWidth: wrapWidth);
      if (message != null) XtifyAudioHandler.noteEngineLog(message);
    };
    final previousOnError = FlutterError.onError;
    final seen = <String>{};
    FlutterError.onError = (details) {
      final first = seen.add(_kindOf(details));
      if (first) {
        add('FLUTTER ERROR (first of its kind): ${details.exceptionAsString()}');
        for (final line in details.toString().split('\n').take(45)) {
          if (line.trim().isNotEmpty) add('  $line');
        }
        FlutterError.dumpErrorToConsole(details, forceReport: true);
      } else {
        add('FLUTTER ERROR: ${details.exceptionAsString()}');
        previousOnError?.call(details);
      }
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      add('UNCAUGHT: $error\n${_trim(stack)}');
      return false;
    };
  }

  static final RegExp _bad = RegExp(
      r'fail|error|exception|uncaught|could not|crash|403', caseSensitive: false);
  static final RegExp _warn = RegExp(
      r'blocked|retry|timeout|timed out|dropped|skipped|stuck|recover|expired|busy|offline',
      caseSensitive: false);
  static final RegExp _good = RegExp(
      r'took \d+ms|initiali[sz]ed|picked|matched|found a client id|audio url from|playing',
      caseSensitive: false);
  static final RegExp _videoId = RegExp(r'^\[[A-Za-z0-9_-]{11}\]');

  static String _color(String m) {
    const reset = '\x1B[0m';
    final code = _bad.hasMatch(m)
        ? '\x1B[1;31m'
        : _warn.hasMatch(m)
            ? '\x1B[33m'
            : _good.hasMatch(m)
                ? '\x1B[32m'
                : null;
    final id = _videoId.firstMatch(m);
    var body = m;
    if (id != null) {
      body = '\x1B[36m${id[0]}$reset${code ?? ''}${m.substring(id.end)}';
    } else if (code != null) {
      body = '$code$m';
    } else {
      return m;
    }
    return '$body$reset';
  }

  static String _trim(StackTrace? s) =>
      (s?.toString() ?? '').split('\n').take(8).join('\n');

  static String _kindOf(FlutterErrorDetails d) {
    final firstLine = d.exceptionAsString().split('\n').first;
    return '${d.library}|${firstLine.replaceAll(RegExp(r'[0-9][0-9.,e+-]*'), '#')}';
  }

  static void add(String message) {
    final text = _clean(message);
    if (text == _last) {
      _repeats++;
      return;
    }
    _closeRepeats();
    _last = text;
    _put(text);
  }

  static void _closeRepeats() {
    if (_repeats == 0) return;
    final count = _repeats;
    _repeats = 0;
    _put('  (the line above repeated $count more times)');
  }

  static void _put(String text) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    final line = '$t $text';
    _lines.addLast(line);
    while (_lines.length > _max) {
      _lines.removeFirst();
    }
    _store?.add(line);
  }

  static String _clean(String m) {
    var s = m;
    s = s.replaceAllMapped(RegExp(r'(https?://[^\s?]+)\?\S{20,}'), (x) => '${x[1]}?…');
    s = s.replaceAllMapped(
        RegExp(r'(cookie|authorization|sapisid|sid|token|key)(=|:)\s*\S+', caseSensitive: false),
        (x) => '${x[1]}${x[2]}…');
    return s.length > 600 ? '${s.substring(0, 600)}…' : s;
  }

  static String report() {
    final h = XtifyAudioHandler.instance;
    final ps = h.playbackState.value;
    final cur = h.currentTrack;
    final b = StringBuffer()
      ..writeln('Xtify debug info')
      ..writeln('Time: ${DateTime.now().toIso8601String()}')
      ..writeln('App: $_version')
      ..writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('Encrypted storage: ${Vault.instance.summary}')
      ..writeln('Online: ${ConnectivityService.instance.online.value}')
      ..writeln('Signed in to YouTube: ${CookieService.instance.signedInListener.value}'
          '${CookieService.instance.needsSignInListener.value ? ' (expired)' : ''}')
      ..writeln('Now playing: ${cur == null ? '-' : '${cur.title} (${cur.id})'}')
      ..writeln('Player: ${ps.processingState.name}, playing=${ps.playing}')
      ..writeln('Downloads: ${DownloadService.instance.items.value.length}, '
          'history: ${HistoryService.instance.tracks.value.length}')
      ..writeln();
    _writeRecords(b);
    _writeLogs(b);
    return b.toString();
  }

  static Future<void> copy() => Clipboard.setData(ClipboardData(text: report()));

  static void _writeRecords(StringBuffer b) {
    final store = _store;
    if (store == null) return;
    final text = AndroidRecords.read(store.directory, _recordsLimit);
    if (text.isEmpty) return;
    b
      ..writeln('--- Android records ---')
      ..writeln(text)
      ..writeln();
  }

  static void _writeLogs(StringBuffer b) {
    flush();
    final store = _store;
    final sessions = store == null ? const <LogSession>[] : store.sessions();
    if (store == null || sessions.isEmpty) {
      b.writeln('--- last log lines ---');
      for (final line in _lines) {
        b.writeln(line);
      }
      return;
    }
    final sections = <String>[];
    for (var i = sessions.length - 1, rank = 0;
        i >= 0 && rank < _budgets.length;
        i--, rank++) {
      final s = sessions[i];
      final label = s.number == store.number
          ? 'this session'
          : rank <= 1
              ? 'previous session'
              : 'earlier session';
      sections.add(_section(label, s.text, _budgets[rank]));
    }
    for (final section in sections.reversed) {
      b.write(section);
    }
  }

  static String _section(String label, String text, int budget) {
    final lines = const LineSplitter().convert(text);
    final first = lines.isNotEmpty && lines.first.startsWith('=== ') ? 1 : 0;
    var start = lines.length;
    var used = 0;
    while (start > first) {
      final cost = lines[start - 1].length + 1;
      if (used + cost > budget) break;
      used += cost;
      start--;
    }
    final out = StringBuffer()..writeln('--- $label ---');
    if (first == 1) out.writeln(lines.first);
    if (start > first) out.writeln('(${start - first} earlier lines left out)');
    for (var i = start; i < lines.length; i++) {
      out.writeln(lines[i]);
    }
    return out.toString();
  }
}

class _Watcher with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    DebugLog.add('app: ${state.name}, memory ${DebugLog._memory()}');
    if (state != AppLifecycleState.resumed) DebugLog.flush();
  }

  @override
  void didHaveMemoryPressure() {
    DebugLog.add('app: low memory warning, memory ${DebugLog._memory()}');
    DebugLog.flush();
  }
}
