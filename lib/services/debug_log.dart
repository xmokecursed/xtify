import 'dart:collection';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'connectivity_service.dart';
import 'cookie_service.dart';
import 'download_service.dart';
import 'history_service.dart';
import 'audio_service.dart';

/// Keeps the last log lines and uncaught errors in memory so they can be copied
/// from the Library tab and pasted into a bug report.
class DebugLog {
  DebugLog._();
  static const int _max = 400;
  static final Queue<String> _lines = Queue<String>();

  static void install() {
    final original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) add(message);
      original(message == null ? null : _color(message), wrapWidth: wrapWidth);
    };
    final previousOnError = FlutterError.onError;
    // Flutter prints a full report only for the very first error of a run and a
    // one-line summary for every later one, which is exactly how the details of
    // the error that mattered got lost. So the first error of each KIND is
    // printed in full (and kept in full in the copied debug info); repeats of
    // the same kind stay one line.
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
      return false; // still reported as usual
    };
  }

  // Colours for the terminal only (the copied debug info stays plain text):
  // red = failures, yellow = retries and waiting, green = things that worked.
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
      // the video id in cyan, so one song's lines are easy to follow
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

  /// Errors that only differ in numbers (sizes, animation values, line numbers)
  /// count as the same kind.
  static String _kindOf(FlutterErrorDetails d) {
    final firstLine = d.exceptionAsString().split('\n').first;
    return '${d.library}|${firstLine.replaceAll(RegExp(r'[0-9][0-9.,e+-]*'), '#')}';
  }

  static void add(String message) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    _lines.addLast('$t ${_clean(message)}');
    while (_lines.length > _max) {
      _lines.removeFirst();
    }
  }

  /// Takes out anything private: cookie values, signed stream links, tokens.
  static String _clean(String m) {
    var s = m;
    s = s.replaceAllMapped(RegExp(r'(https?://[^\s?]+)\?\S{20,}'), (x) => '${x[1]}?…');
    s = s.replaceAllMapped(
        RegExp(r'(cookie|authorization|sapisid|sid|token|key)(=|:)\s*\S+', caseSensitive: false),
        (x) => '${x[1]}${x[2]}…');
    return s.length > 600 ? '${s.substring(0, 600)}…' : s;
  }

  /// Everything worth sending along with a bug report.
  static String report() {
    final h = XtifyAudioHandler.instance;
    final ps = h.playbackState.value;
    final cur = h.currentTrack;
    final b = StringBuffer()
      ..writeln('Xtify debug info')
      ..writeln('Time: ${DateTime.now().toIso8601String()}')
      ..writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('Online: ${ConnectivityService.instance.online.value}')
      ..writeln('Signed in to YouTube: ${CookieService.instance.signedInListener.value}'
          '${CookieService.instance.needsSignInListener.value ? ' (expired)' : ''}')
      ..writeln('Now playing: ${cur == null ? '-' : '${cur.title} (${cur.id})'}')
      ..writeln('Player: ${ps.processingState.name}, playing=${ps.playing}')
      ..writeln('Downloads: ${DownloadService.instance.items.value.length}, '
          'history: ${HistoryService.instance.tracks.value.length}')
      ..writeln()
      ..writeln('--- last log lines ---')
      ..writeAll(_lines, '\n');
    return b.toString();
  }

  static Future<void> copy() => Clipboard.setData(ClipboardData(text: report()));
}
