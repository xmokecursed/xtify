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
      original(message, wrapWidth: wrapWidth);
    };
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      add('FLUTTER ERROR: ${details.exceptionAsString()}\n${_trim(details.stack)}');
      previousOnError?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      add('UNCAUGHT: $error\n${_trim(stack)}');
      return false; // still reported as usual
    };
  }

  static String _trim(StackTrace? s) =>
      (s?.toString() ?? '').split('\n').take(8).join('\n');

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
