import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:discord_rich_presence/discord_rich_presence.dart'
    show Activity, ActivityAssets, ActivityTimestamps, ActivityType, Client;
import 'package:flutter/foundation.dart';

import '../desktop/desktop_scope.dart';
import 'audio_service.dart';

class _Shown {
  final String id;
  final DateTime start;
  final DateTime? end;
  const _Shown(this.id, this.start, this.end);
}

class DiscordPresenceService {
  DiscordPresenceService._();
  static final DiscordPresenceService instance = DiscordPresenceService._();

  static const String _applicationId = '1570838705583951982';
  static const String _fallbackArt =
      'https://raw.githubusercontent.com/xmokecursed/xtify/main/assets/icon/logo.png';

  static const Duration _pauseGrace = Duration(seconds: 10);
  static const Duration _minGap = Duration(seconds: 4);
  static const Duration _retryGap = Duration(seconds: 20);
  static const Duration _drift = Duration(seconds: 2);

  final List<StreamSubscription<Object?>> _subs = [];
  Future<void> _tail = Future<void>.value();
  Client? _client;
  _Shown? _shown;
  Timer? _throttle;
  Timer? _pauseTimer;
  Timer? _retryTimer;
  bool _started = false;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFail = DateTime.fromMillisecondsSinceEpoch(0);

  void start() {
    if (_started || !isDesktopPlatform) return;
    _started = true;
    final handler = XtifyAudioHandler.instance;
    _subs.add(handler.mediaItem.listen((_) => _schedule()));
    _subs.add(handler.playbackState.listen((_) => _schedule()));
    _schedule();
  }

  void _schedule() {
    if (_throttle?.isActive ?? false) return;
    final since = DateTime.now().difference(_lastSend);
    final wait = since >= _minGap
        ? const Duration(milliseconds: 500)
        : _minGap - since;
    _throttle = Timer(wait, () => _run(_apply));
  }

  void _run(Future<void> Function() job) {
    _tail = _tail.then((_) => job()).catchError((Object e) {
      debugPrint('discord: ${_short(e)}');
    });
  }

  bool _isActive() {
    final handler = XtifyAudioHandler.instance;
    final state = handler.playbackState.value;
    return handler.mediaItem.valueOrNull != null &&
        state.playing &&
        state.processingState != AudioProcessingState.idle &&
        state.processingState != AudioProcessingState.completed;
  }

  Future<void> _apply() async {
    if (!_isActive()) {
      if (_client != null && !(_pauseTimer?.isActive ?? false)) {
        _pauseTimer = Timer(_pauseGrace, () => _run(_clearIfIdle));
      }
      return;
    }
    _pauseTimer?.cancel();
    _pauseTimer = null;

    final handler = XtifyAudioHandler.instance;
    final item = handler.mediaItem.valueOrNull!;
    final state = handler.playbackState.value;

    final start = DateTime.now().subtract(state.position);
    final total = item.duration;
    final end = (total != null && total > Duration.zero) ? start.add(total) : null;

    final shown = _shown;
    if (_client != null &&
        shown != null &&
        shown.id == item.id &&
        (shown.start.difference(start)).abs() < _drift &&
        ((shown.end == null) == (end == null)) &&
        (end == null || (shown.end!.difference(end)).abs() < _drift)) {
      return;
    }

    if (!await _connect()) {
      _retryTimer?.cancel();
      _retryTimer = Timer(_retryGap, _schedule);
      return;
    }

    final track = handler.currentTrack;
    final artist = item.artist?.trim() ?? '';
    final activity = Activity(
      name: 'Xtify',
      type: ActivityType.listening,
      details: _clip(item.title),
      state: artist.isEmpty ? null : _clip(artist),
      timestamps: ActivityTimestamps(start: start, end: end),
      assets: ActivityAssets(
        largeImage: _art(item, track?.id == item.id ? track?.imageUrl : null),
      ),
    );

    try {
      await _client!.setActivity(activity).timeout(const Duration(seconds: 5));
      _lastSend = DateTime.now();
      _shown = _Shown(item.id, start, end);
    } catch (e) {
      debugPrint('discord: could not update the presence (${_short(e)}), reconnecting');
      await _drop();
      _retryTimer?.cancel();
      _retryTimer = Timer(_retryGap, _schedule);
    }
  }

  Future<bool> _connect() async {
    if (_client != null) return true;
    if (DateTime.now().difference(_lastFail) < _retryGap) return false;
    final client = Client(clientId: _applicationId);
    try {
      await client.connect().timeout(const Duration(seconds: 6));
      _client = client;
      debugPrint('discord: connected');
      return true;
    } catch (e) {
      _lastFail = DateTime.now();
      debugPrint('discord: not available (${_short(e)})');
      unawaited(client.disconnect().catchError((Object _) {}));
      return false;
    }
  }

  Future<void> _clearIfIdle() async {
    _pauseTimer = null;
    if (_isActive()) return;
    await _drop();
  }

  Future<void> _drop() async {
    final client = _client;
    _client = null;
    _shown = null;
    if (client == null) return;
    try {
      await client.disconnect();
    } catch (_) {}
  }

  static String _art(MediaItem item, String? trackArt) {
    if (trackArt != null && trackArt.startsWith('http')) return trackArt;
    final uri = item.artUri;
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return uri.toString();
    }
    return _fallbackArt;
  }

  static String _clip(String s) {
    var out = s.trim();
    if (out.length > 128) out = '${out.substring(0, 127)}…';
    if (out.length < 2) out = '$out\u200b';
    return out;
  }

  static String _short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 200 ? s.substring(0, 200) : s;
  }
}
