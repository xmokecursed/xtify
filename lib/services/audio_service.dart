import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/track_model.dart';
import '../services/audio_url_resolver.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';
import '../services/history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'artist_credit.dart';
import 'auto_queue_service.dart';
import 'auto_queue_settings.dart';
import 'chunked_audio_source.dart';
import 'cookie_service.dart';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

enum XtifyRepeat { off, all, one }

class XtifyAudioHandler extends BaseAudioHandler with SeekHandler {
  final _player = AudioPlayer();
  static XtifyAudioHandler? _instance;
  final BehaviorSubject<MediaItem?> _mediaItem = BehaviorSubject<MediaItem?>();
  final BehaviorSubject<List<MediaItem>> _queue = BehaviorSubject<List<MediaItem>>.seeded([]);
  int _playToken = 0;
  final AutoQueueService _autoQueue = AutoQueueService();
  final Map<String, Track> _tracksById = {};
  final Map<String, ResolvedAudioUrl> _queuedUrls = {};
  Track? _currentTrack;
  List<Track> _context = const [];
  List<Track> _ctxOriginal = const [];
  String? _ctxCursorId;

  List<Track> _userQueue = [];
  Track? _preloaded;
  bool _preloadedFromUser = false;
  int _prepareEpoch = 0;
  DateTime _lastSongStart = DateTime.fromMillisecondsSinceEpoch(0);
  final ValueNotifier<List<Track>> upNextQueue = ValueNotifier<List<Track>>(const []);
  final ValueNotifier<bool> shuffleOn = ValueNotifier<bool>(false);
  final ValueNotifier<XtifyRepeat> repeat = ValueNotifier<XtifyRepeat>(XtifyRepeat.off);
  final ValueNotifier<double> volume = ValueNotifier<double>(1.0);
  double _volumeBeforeMute = 1.0;

  Track? get currentTrack => _currentTrack;
  bool _nextQueued = false;
  bool _preparingNext = false;
  bool _settingSource = false;
  int _prepareAttempts = 0;
  int _loading = 0;
  DateTime _loadingSince = DateTime.fromMillisecondsSinceEpoch(0);
  bool get _loadingSong =>
      _loading > 0 && DateTime.now().difference(_loadingSince) < const Duration(seconds: 40);
  DateTime _lastPrepareAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _prepareLead = Duration(hours: 24);
  final ValueNotifier<bool> findingNext = ValueNotifier<bool>(false);
  bool _sourceLoaded = false;
  Duration _restoredPosition = Duration.zero;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);

  XtifyAudioHandler() {
    _instance = this;
    _init().catchError((e) {
      if (bool.fromEnvironment('dart.vm.product') == false) {
        debugPrint('Audio handler initialization error: $e');
      }
    });

    _player.durationStream.listen((duration) {
      final current = _mediaItem.valueOrNull;
      if (current != null) {
        final updated = current.copyWith(duration: duration);
        _mediaItem.add(updated);
      }
    });

    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        if (DateTime.now().difference(_lastSongStart) < const Duration(seconds: 4)) {
          debugPrint('player: ignored a stale "completed" right after a song started');
          return;
        }
        if (repeat.value == XtifyRepeat.one) {
          _player.seek(Duration.zero).then((_) => _player.play());
          return;
        }
        skipToNext().catchError((Object e) {
          debugPrint('auto-advance failed: $e');
        });
      }
    });
    _watchdogTimer = Timer.periodic(const Duration(seconds: 4), (_) => _watchdog());
    _player.positionStream.listen(_onPosition);
    _player.currentIndexStream.listen(_onIndexChanged);
    _player.errorStream.listen((error) {
      debugPrint('Audio player error: $error');
      final current = _mediaItem.valueOrNull;
      final videoId = current?.extras?['videoId'] as String?;
      if (videoId != null && videoId.isNotEmpty) {
        AudioUrlResolver.clearCache(videoId);
      }
      if (_settingSource) return;
      try {
        final idx = error.index;
        final cur = _player.currentIndex;
        if (idx == null || idx == cur) {
          debugPrint('current song failed, reloading it');
          _recoverCurrent();
          return;
        }
        if (idx >= _player.sequence.length) return;
        final item = _player.sequence[idx].tag as MediaItem?;
        final track = item == null ? null : _tracksById[item.id];
        if (track == null) return;
        AudioUrlResolver.clearCache(track.id);
        _player.removeAudioSourceAt(idx).catchError((Object e) {});
        _nextQueued = false;
        _preloaded = null;
        _preloadedFromUser = false;
        _publishQueue();
      } catch (e) {
        debugPrint('error recovery failed: $e');
      }
    });
  }

  Timer? _watchdogTimer;
  bool _recovering = false;
  bool _gaveUp = false;
  int _recoveryStreak = 0;
  DateTime _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _wdPos = Duration.zero;
  DateTime _wdAt = DateTime.now();

  Future<void> _recoverCurrent({Duration? at, bool force = false}) async {
    final t = _currentTrack;
    if (t == null || _recovering || !_sourceLoaded) return;
    final now = DateTime.now();
    _recoveryStreak = now.difference(_lastRecovery) < const Duration(seconds: 30)
        ? _recoveryStreak + 1
        : 0;
    if (!force && _recoveryStreak >= 3) {
      if (!_gaveUp) debugPrint('recovery: giving up after $_recoveryStreak quick failures, press play to retry');
      _gaveUp = true;
      return;
    }
    _gaveUp = false;
    _recovering = true;
    _lastRecovery = now;
    final pos = at ?? _player.position;
    try {
      AudioUrlResolver.clearCache(t.id);
      await playTrack(t, userInitiated: false, keepContext: true, startAt: pos);
    } catch (e) {
      debugPrint('recovery failed: ${_short(e)}');
    } finally {
      _recovering = false;
      _wdAt = DateTime.now();
    }
  }

  void _watchdog() {
    final now = DateTime.now();
    if (!_sourceLoaded || _recovering || _settingSource || _gaveUp || _currentTrack == null) {
      _wdAt = now;
      return;
    }
    final st = _player.processingState;
    final pos = _player.position;
    if (!_player.playing || st == ProcessingState.completed) {
      _wdAt = now;
      _wdPos = pos;
      return;
    }
    if (pos != _wdPos && st != ProcessingState.idle) {
      _wdPos = pos;
      _wdAt = now;
      return;
    }
    final limit = st == ProcessingState.ready
        ? const Duration(seconds: 12)
        : const Duration(seconds: 25);
    if (st == ProcessingState.idle || now.difference(_wdAt) > limit) {
      debugPrint('watchdog: playback stuck ($st), reloading');
      _wdAt = now;
      _recoverCurrent();
    }
  }

  static XtifyAudioHandler get instance => _instance!;

  @override
  BehaviorSubject<MediaItem?> get mediaItem => _mediaItem;

  @override
  BehaviorSubject<List<MediaItem>> get queue => _queue;

  Future<void> _init() async {
    _player.playbackEventStream.map(_transformEvent).listen((state) {
      playbackState.add(state);
    });
  }

  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: _getPlaybackControls(),
      systemActions: const {
        MediaAction.seek,
        MediaAction.skipToNext,
        MediaAction.skipToPrevious,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _mapJustAudioStateToAudioServiceState(_player.processingState),
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex ?? 0,
    );
  }

  AudioProcessingState _mapJustAudioStateToAudioServiceState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  List<MediaControl> _getPlaybackControls() {
    return [
      MediaControl.skipToPrevious,
      _player.playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
    ];
  }

  @override
  Future<void> play() async {
    final t = _currentTrack;
    if (!_sourceLoaded && t != null) {
      playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.loading, playing: true));
      try {
        await playTrack(t, startAt: _restoredPosition);
      } catch (e) {
        playbackState.add(playbackState.value.copyWith(
            processingState: AudioProcessingState.idle, playing: false));
      }
      return;
    }
    if (_sourceLoaded && _player.processingState == ProcessingState.idle) {
      await _recoverCurrent(force: true);
      return;
    }
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _savePosition(_player.position);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_sourceLoaded && _player.processingState == ProcessingState.idle) {
      return _recoverCurrent(at: position, force: true);
    }
    if (_sourceLoaded) return _player.seek(position);
    _restoredPosition = position;
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _sourceLoaded = false;
  }

  void _savePosition(Duration pos) {
    _lastSaved = DateTime.now();
    SharedPreferences.getInstance().then((p) => p.setInt('last_pos_ms', pos.inMilliseconds));
  }

  Future<void> restoreLast() async {
    final last = HistoryService.instance.tracks.value.firstOrNull;
    if (last == null || _currentTrack != null) return;
    final item = createMediaItem(last);
    final saved = (await SharedPreferences.getInstance()).getInt('last_pos_ms') ?? 0;
    var pos = Duration(milliseconds: saved);
    final total = item.duration;
    if (total != null && pos >= total - const Duration(seconds: 3)) pos = Duration.zero;
    _currentTrack = last;
    _tracksById[last.id] = last;
    _restoredPosition = pos;
    _queue.add([item]);
    _mediaItem.add(item);
    playbackState.add(PlaybackState(
      controls: _getPlaybackControls(),
      systemActions: const {MediaAction.seek, MediaAction.skipToNext, MediaAction.skipToPrevious},
      processingState: AudioProcessingState.idle,
      playing: false,
      updatePosition: pos,
    ));
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    final List<MediaItem> newQueue = List<MediaItem>.from(_queue.value);
    newQueue.add(mediaItem);
    _queue.add(newQueue);
    _mediaItem.add(mediaItem);
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    final List<MediaItem> newQueue = List<MediaItem>.from(_queue.value);
    newQueue.addAll(mediaItems);
    _queue.add(newQueue);
    if (mediaItems.isNotEmpty) {
      _mediaItem.add(mediaItems.last);
    }
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) {
    final List<MediaItem> newQueue = List<MediaItem>.from(_queue.value)
        .where((item) => item.id != mediaItem.id)
        .toList();
    _queue.add(newQueue);
    if (newQueue.isNotEmpty) {
      _mediaItem.add(newQueue.last);
    } else {
      _mediaItem.add(null);
      stop();
    }
    return Future.value();
  }

  @override
  Future<void> skipToQueueItem(int index) {
    final List<MediaItem> queueValue = _queue.value;
    if (index >= 0 && index < queueValue.length) {
      return _player.seek(Duration.zero, index: index);
    }
    return Future.value();
  }

  bool _advancing = false;
  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
      return;
    }
    final seed = _currentTrack;
    if (seed == null || _advancing) return;
    _advancing = true;
    findingNext.value = true;
    try {
      final next = await _nextTrack(seed);
      if (next == null) return;
      _consumeUserHead(next);
      await playTrack(next, userInitiated: false, keepContext: true);
    } finally {
      _advancing = false;
      findingNext.value = false;
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final h = HistoryService.instance.tracks.value;
    if (_player.position > const Duration(seconds: 3) || h.length < 2) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_context.isNotEmpty && _currentTrack != null) {
      final i = _context.indexWhere((t) => t.id == _currentTrack!.id);
      if (i > 0) {
        await playTrack(_context[i - 1], userInitiated: false, keepContext: true);
        return;
      }
    }
    await playTrack(h[1], userInitiated: false);
  }

  Future<void> clearQueue() {
    _queue.add(<MediaItem>[]);
    _mediaItem.add(null);
    return stop();
  }

  Future<double> getSpeed() => _player.speedStream.first;

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> playTrack(Track track,
      {bool userInitiated = true,
      bool keepContext = false,
      Duration? startAt,
      String? searchedFor}) async {
    _loading++;
    _loadingSince = DateTime.now();
    try {
      await _playTrack(track,
          userInitiated: userInitiated,
          keepContext: keepContext,
          startAt: startAt,
          searchedFor: searchedFor);
    } finally {
      _loading--;
    }
  }

  Future<void> _playTrack(Track track,
      {required bool userInitiated,
      required bool keepContext,
      Duration? startAt,
      String? searchedFor}) async {
    final token = ++_playToken;
    _gaveUp = false;
    if (_preloaded != null && _preloadedFromUser) _userQueue = [_preloaded!, ..._userQueue];
    _preloaded = null;
    _preloadedFromUser = false;
    _prepareEpoch++;
    _userQueue = _userQueue.where((x) => x.id != track.id).toList();
    _publishQueue();
    final mediaItem = XtifyAudioHandler.createMediaItem(track);
    final videoId = (mediaItem.extras?['videoId'] as String?) ?? '';
    if (videoId.isEmpty) throw Exception('Missing video ID in media item');
    _nextQueued = false;
    _preparingNext = false;
    findingNext.value = false;
    _prepareAttempts = 0;
    _queuedUrls.clear();
    _currentTrack = track;
    if (!keepContext) {
      _context = const [];
      _ctxOriginal = const [];
      _ctxCursorId = null;
    }
    _tracksById[track.id] = track;
    if (userInitiated) {
      _autoQueue.startSession(track, searchedFor: searchedFor);
    } else {
      _autoQueue.advanced(track);
    }
    _queue.add([mediaItem]);
    _mediaItem.add(mediaItem);

    final errors = <String>[];

    final saved = _localUrl(videoId);
    if (saved != null) {
      if (await _tryPlay(saved, mediaItem, token, errors, 'downloaded', start: startAt)) {
        _started(track);
        return;
      }
      if (token != _playToken) return;
    }

    final cached = AudioUrlResolver.cached(videoId);
    if (cached != null) {
      if (await _tryPlay(cached, mediaItem, token, errors, 'cached', start: startAt)) {
        _started(track);
        return;
      }
      if (token != _playToken) return;
      AudioUrlResolver.clearCache(videoId);
    }

    final pre = await AudioUrlResolver.takePrefetched(videoId);
    if (pre != null) {
      if (token != _playToken) return;
      if (await _tryPlay(pre, mediaItem, token, errors, 'prefetched', start: startAt)) {
        AudioUrlResolver.markWorking(videoId, AudioUrlResolver.preferredStrategy, pre);
        _started(track);
        return;
      }
      if (token != _playToken) return;
    }

    for (final idx in AudioUrlResolver.attemptOrder(videoId)) {
      if (token != _playToken) return;
      final label = AudioUrlResolver.strategyLabel(idx);
      try {
        final resolved =
            await AudioUrlResolver().resolve(videoId, strategyIndex: idx);
        if (token != _playToken) return;
        if (await _tryPlay(resolved, mediaItem, token, errors, label, start: startAt)) {
          AudioUrlResolver.markWorking(videoId, idx, resolved);
          _started(track);
          return;
        }
      } catch (e) {
        errors.add('$label: ${_short(e)}');
        debugPrint('resolve failed ($label): ${_short(e)}');
        if (e is TimeoutException) break;
      }
    }

    if (token == _playToken) {
      final all = errors.join(' | ');
      if (CookieService.looksLikeAuthError(all)) CookieService.instance.markExpired();
      throw Exception('Could not play this track. $all');
    }
  }

  Future<bool> _tryPlay(ResolvedAudioUrl r, MediaItem item, int token,
      List<String> errors, String label, {Duration? start}) async {
    _settingSource = true;
    try {
      final sw = Stopwatch()..start();
      await _player.setAudioSource(
        audioSourceFor(r.url, headers: r.headers, tag: item),
        initialPosition: start,
      );
      debugPrint('setAudioSource ($label) took ${sw.elapsedMilliseconds}ms');
      if (token != _playToken) return false;
      _sourceLoaded = true;
      _lastSongStart = DateTime.now();
      _player.play();
      debugPrint('playing via $label');
      return true;
    } catch (e) {
      errors.add('$label: ${_short(e)}');
      debugPrint('play attempt failed ($label): ${_short(e)}');
      if (r.url.contains('googlevideo.com')) unawaited(AudioUrlResolver.probe(r.url));
      return false;
    } finally {
      _settingSource = false;
    }
  }

  Future<void> playPlaylist(List<Track> tracks,
      {int startIndex = 0, bool shuffle = false}) async {
    final offline = !ConnectivityService.instance.online.value;
    bool ok(Track t) =>
        t.isPlayable && (!offline || DownloadService.instance.isDownloaded(t.id));
    final playable = tracks.where(ok).toList();
    if (playable.isEmpty) {
      throw Exception(offline
          ? 'No downloaded songs here to play offline'
          : 'No playable songs in this playlist');
    }
    final startTrack =
        (startIndex >= 0 && startIndex < tracks.length && ok(tracks[startIndex]))
            ? tracks[startIndex]
            : playable.first;
    _ctxOriginal = [...playable];
    shuffleOn.value = shuffle;
    final list = [...playable];
    if (shuffle) {
      list.removeWhere((t) => t.id == startTrack.id);
      list.shuffle();
      list.insert(0, startTrack);
    }
    _context = list;
    _ctxCursorId = startTrack.id;
    await playTrack(startTrack, keepContext: true);
  }

  int _ctxIndex(Track seed) {
    var i = _context.indexWhere((t) => t.id == seed.id);
    if (i < 0 && _ctxCursorId != null) {
      i = _context.indexWhere((t) => t.id == _ctxCursorId);
    }
    return i;
  }

  Track? _contextNext(Track seed, bool offline) {
    if (_context.isEmpty) return null;
    final base = _ctxIndex(seed);
    if (base < 0) return null;
    bool ok(Track t) => !offline || DownloadService.instance.isDownloaded(t.id);
    for (var j = base + 1; j < _context.length; j++) {
      if (ok(_context[j])) return _context[j];
    }
    if (repeat.value == XtifyRepeat.all) {
      for (var j = 0; j <= base; j++) {
        if (ok(_context[j])) return _context[j];
      }
    }
    return null;
  }

  Future<Track?> _nextTrack(Track seed) async {
    if (_userQueue.isNotEmpty) return _userQueue.first;
    final offline = !ConnectivityService.instance.online.value;
    final inContext = _contextNext(seed, offline);
    if (inContext != null) return inContext;
    if (offline) {
      final followed = _autoQueue.focusFor(seed);
      var saved = DownloadService.instance.items.value.values
          .map((e) => e.track)
          .where((t) => t.id != seed.id)
          .toList();
      if (followed != null) {
        final mine = saved.where((t) => ArtistCredit.of(t).has(followed)).toList();
        if (mine.isNotEmpty) saved = mine;
      }
      saved.shuffle();
      return saved.firstOrNull;
    }
    final next = await _autoQueue.nextFor(seed);
    if (next != null) return next;
    final focus = _autoQueue.focusFor(seed);
    final a = seed.artist.trim().toLowerCase();
    if (focus == null && a.isEmpty) return null;
    final others = HistoryService.instance.tracks.value
        .where((t) =>
            t.id != seed.id &&
            (focus != null
                ? ArtistCredit.of(t).has(focus)
                : t.artist.trim().toLowerCase() == a))
        .toList()
      ..shuffle();
    return others.firstOrNull;
  }

  bool _autoQueueDrives(Track seed) {
    if (_userQueue.isNotEmpty || _preloadedFromUser) return false;
    final offline = !ConnectivityService.instance.online.value;
    return _contextNext(seed, offline) == null;
  }

  Future<void> _autoQueueChanged() async {
    _autoQueue.restart();
    final t = _currentTrack;
    if (t == null || !_autoQueueDrives(t)) return;
    final followed = _autoQueue.focusFor(t);
    final waiting = _preloaded;
    final fits = _nextQueued &&
        waiting != null &&
        (followed == null || ArtistCredit.of(waiting).has(followed));
    final who = followed == null ? 'similar songs' : 'only songs by "$followed"';
    final next = waiting == null
        ? 'no next song chosen yet'
        : fits
            ? 'next song kept: "${waiting.title}"'
            : 'next song replaced: "${waiting.title}"';
    debugPrint('auto-queue: setting changed ($who), $next');
    if (!fits) await _dropPreloaded();
    _autoQueue.warm(t);
    if (fits) return;
    final dur = _player.duration;
    if (_sourceLoaded && dur != null && dur > Duration.zero) _prepareNext();
  }

  Future<void> setAutoQueueMode(AutoQueueMode mode) async {
    final settings = AutoQueueSettings.instance;
    if (settings.mode.value == mode) return;
    await settings.setMode(mode);
    await _autoQueueChanged();
  }

  void _consumeUserHead(Track t) {
    if (_userQueue.isNotEmpty && _userQueue.first.id == t.id) {
      _userQueue = _userQueue.sublist(1);
      _publishQueue();
    }
  }

  void _started(Track t) {    
    HistoryService.instance.add(t);    
    if (_context.any((x) => x.id == t.id)) _ctxCursorId = t.id;
    final i = _ctxIndex(t);
    final playlistHasNext = i >= 0 &&
        (i + 1 < _context.length || repeat.value == XtifyRepeat.all);
    if (!playlistHasNext && _userQueue.isEmpty) {
      _autoQueue.warm(t);
    }  
  }  

  void _onPosition(Duration pos) {
    if (_sourceLoaded && DateTime.now().difference(_lastSaved) > const Duration(seconds: 5)) {
      _savePosition(pos);
    }
    if (_nextQueued || _preparingNext || _currentTrack == null || _loadingSong) return;
    final dur = _player.duration;    
    if (dur == null || dur == Duration.zero) return;    
    if (dur - pos > _prepareLead) return;    
    if (_prepareAttempts >= 6) return;    
    if (DateTime.now().difference(_lastPrepareAt) < Duration(seconds: 6 * (_prepareAttempts + 1))) return;
    _prepareNext();  
  }  

  Future<void> _prepareNext() async {
    final seed = _currentTrack;
    if (seed == null || _preparingNext || _nextQueued || _loadingSong) return;
    if (repeat.value == XtifyRepeat.one) return;
    _preparingNext = true;
    findingNext.value = true;
    _prepareAttempts++;
    _lastPrepareAt = DateTime.now();
    final token = _playToken;
    final epoch = _prepareEpoch;
    bool stale() => token != _playToken || epoch != _prepareEpoch;
    final sw = Stopwatch()..start();
    try {
      final next = await _nextTrack(seed);
      if (next == null) {
        debugPrint('auto-queue: no candidate for "${seed.title}"');
        return;
      }
      if (next.id == seed.id) return;
      if (stale()) return;
      final fromUser = _userQueue.isNotEmpty && _userQueue.first.id == next.id;
      final resolved = await _resolveForQueue(next.id);
      if (resolved == null || stale()) return;
      final item = createMediaItem(next);
      _tracksById[next.id] = next;
      _queuedUrls[next.id] = resolved;
      await _removeWaiting();
      await _player.addAudioSource(
        audioSourceFor(resolved.url, headers: resolved.headers, tag: item),
      );
      if (stale()) {
        await _removeWaiting();
        return;
      }
      _nextQueued = true;
      _preloaded = next;
      _preloadedFromUser = fromUser;
      if (fromUser) _consumeUserHead(next);
      _queue.add([..._queue.value, item]);
      _publishQueue();
      debugPrint('auto-queue: "${next.title}" ready in ${sw.elapsedMilliseconds}ms '
          '(player has ${_player.sequence.length} source(s), at ${_player.currentIndex})');
    } catch (e) {
      debugPrint('auto-queue failed: ${_short(e)}');
    } finally {
      if (token == _playToken) {
        _preparingNext = false;
        findingNext.value = false;
      }
    }
  }

  void _publishQueue() {
    upNextQueue.value = [
      if (_preloadedFromUser && _preloaded != null) _preloaded!,
      ..._userQueue,
    ];
  }

  Future<void> _removeWaiting() async {
    try {
      final cur = _player.currentIndex ?? 0;
      final len = _player.sequence.length;
      if (len > cur + 1) {
        debugPrint('player: removing ${len - cur - 1} waiting song(s)');
        await _player.removeAudioSourceRange(cur + 1, len);
      }
    } catch (e) {
      debugPrint('could not remove the waiting song(s): $e');
    }
  }

  Future<void> _dropPreloaded() async {
    _prepareEpoch++;
    _prepareAttempts = 0;
    _lastPrepareAt = DateTime.fromMillisecondsSinceEpoch(0);
    if (_nextQueued) {
      await _removeWaiting();
      final cur = _mediaItem.valueOrNull;
      if (cur != null) _queue.add([cur]);
      _nextQueued = false;
    }
    final p = _preloaded;
    if (p != null) {
      _queuedUrls.remove(p.id);
      if (_preloadedFromUser) _userQueue = [p, ..._userQueue];
    }
    _preloaded = null;
    _preloadedFromUser = false;
    _publishQueue();
  }

  Future<bool> playNext(Track t) async {
    if (!t.isPlayable) return false;
    if (_currentTrack == null) {
      await playTrack(t);
      return true;
    }
    if (_currentTrack!.id == t.id) return false;
    await _dropPreloaded();
    _tracksById[t.id] = t;
    _userQueue = [t, ..._userQueue.where((x) => x.id != t.id)];
    _publishQueue();
    return true;
  }

  Future<bool> addToQueue(Track t) async {
    if (!t.isPlayable) return false;
    if (_currentTrack == null) {
      await playTrack(t);
      return true;
    }
    if (_currentTrack!.id == t.id) return false;
    await _dropPreloaded();
    if (_userQueue.any((x) => x.id == t.id)) return false;
    _tracksById[t.id] = t;
    _userQueue = [..._userQueue, t];
    _publishQueue();
    return true;
  }

  Future<void> removeFromQueue(int index) async {
    await _dropPreloaded();
    if (index < 0 || index >= _userQueue.length) return;
    _userQueue = [..._userQueue]..removeAt(index);
    _publishQueue();
  }

  Future<void> reorderQueue(int oldIndex, int newIndex) async {
    await _dropPreloaded();
    if (oldIndex < 0 || oldIndex >= _userQueue.length) return;
    final list = [..._userQueue];
    final item = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), item);
    _userQueue = list;
    _publishQueue();
  }

  Future<void> clearUserQueue() async {
    await _dropPreloaded();
    _userQueue = [];
    _publishQueue();
  }

  Future<void> playQueueItem(int index) async {
    await _dropPreloaded();
    if (index < 0 || index >= _userQueue.length) return;
    final t = _userQueue[index];
    _userQueue = [..._userQueue]..removeAt(index);
    _publishQueue();
    await playTrack(t, userInitiated: false, keepContext: true);
  }

  Future<void> setShuffle(bool on) async {
    if (shuffleOn.value == on) return;
    shuffleOn.value = on;
    if (_context.isEmpty) return;
    await _dropPreloaded();
    final cur = _currentTrack;
    final i = cur == null ? -1 : _ctxIndex(cur);
    if (on) {
      _ctxOriginal = [..._context];
      final head = i >= 0 ? _context.sublist(0, i + 1) : <Track>[];
      final tail = (i >= 0 ? _context.sublist(i + 1) : [..._context])..shuffle();
      _context = [...head, ...tail];
    } else if (_ctxOriginal.isNotEmpty) {
      _context = [..._ctxOriginal];
    }
  }

  Future<void> cycleRepeat() async {
    final next = XtifyRepeat.values[(repeat.value.index + 1) % XtifyRepeat.values.length];
    repeat.value = next;
    await _dropPreloaded();
  }

  Future<void> togglePlayPause() async {
    if (_currentTrack == null) return;
    if (playbackState.value.playing) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> seekBy(Duration delta) async {
    if (_currentTrack == null) return;
    var target = (_sourceLoaded ? _player.position : _restoredPosition) + delta;
    final total = _player.duration ?? _mediaItem.valueOrNull?.duration;
    if (total != null && total > Duration.zero && target > total) target = total;
    if (target < Duration.zero) target = Duration.zero;
    await seek(target);
  }

  Timer? _volumeSaveTimer;

  Future<void> setVolume(double value) async {
    final v = value.clamp(0.0, 1.0).toDouble();
    volume.value = v;
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 400), () {
      SharedPreferences.getInstance().then((p) => p.setDouble('volume', v));
    });
    await _player.setVolume(v);
  }

  Future<void> toggleMute() async {
    if (volume.value > 0) {
      _volumeBeforeMute = volume.value;
      await setVolume(0);
    } else {
      await setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 1.0);
    }
  }

  Future<void> restoreVolume() async {
    final saved = (await SharedPreferences.getInstance()).getDouble('volume');
    if (saved == null) return;
    final v = saved.clamp(0.0, 1.0).toDouble();
    volume.value = v;
    if (v > 0) _volumeBeforeMute = v;
    await _player.setVolume(v);
  }

  ResolvedAudioUrl? _localUrl(String videoId) {
    final path = DownloadService.instance.localPath(videoId);
    if (path == null) return null;
    return ResolvedAudioUrl(url: Uri.file(path).toString(), headers: const {});
  }

  Future<ResolvedAudioUrl?> _resolveForQueue(String videoId) async {    
    final local = _localUrl(videoId);
    if (local != null) return local;
    final cached = AudioUrlResolver.cached(videoId);    
    if (cached != null) return cached;    
    if (AudioUrlResolver.canLookUpDirectly(videoId)) {
      try {
        return await AudioUrlResolver().resolve(videoId,
            strategyIndex: AudioUrlResolver.nativeIndex, background: true);
      } catch (e) {
        debugPrint('queue resolve failed (native): ${_short(e)}');
      }
    }
    for (var i = 0; i < 80 && AudioUrlResolver.isBusy; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    final idx = AudioUrlResolver.preferredStrategy % AudioUrlResolver.strategyCount;
    try {
      return await AudioUrlResolver().resolve(videoId, strategyIndex: idx, background: true);
    } catch (e) {
      debugPrint('queue resolve failed (${AudioUrlResolver.strategyLabel(idx)}): ${_short(e)}');
    }
    return null;
  }

  void _onIndexChanged(int? index) {    
    if (index == null) return;    
    List<IndexedAudioSource> seq;    
    try {      
      seq = _player.sequence;    
    } catch (_) {      
      return;    }    
    if (index < 0 || index >= seq.length) return;    
    final item = seq[index].tag as MediaItem?;    
    if (item == null || item.id == _mediaItem.valueOrNull?.id) return;    
    _lastSongStart = DateTime.now();
    _mediaItem.add(item);    
    _preloaded = null;
    _preloadedFromUser = false;
    _publishQueue();
    final track = _tracksById[item.id];    
    if (track != null) {      
      _currentTrack = track;      
      _autoQueue.advanced(track);      
      _started(track);    }    
    _nextQueued = false;    
    _preparingNext = false;    
    findingNext.value = false;
    _prepareAttempts = 0;    
    final r = _queuedUrls.remove(item.id);    
    if (r != null) {      
      AudioUrlResolver.markWorking(item.id, AudioUrlResolver.preferredStrategy, r);    }    
    _queue.add([item]);    
    if (index > 0) {      
      _player.removeAudioSourceRange(0, index).catchError((Object e) {});    }    
    debugPrint('now playing (auto-queue): ${item.title}');  
  }

  static String _short(Object e) {
    final s = e.toString();
    final err = s.split('\n').firstWhere(
      (l) => l.contains('ERROR:'),
      orElse: () => s.replaceAll('\n', ' '),
    );
    return err.length > 300 ? err.substring(0, 300) : err;
  }

  static MediaItem createMediaItem(Track track) {
    return MediaItem(
      id: track.id,
      album: track.album,
      title: track.title,
      artist: track.artist,
      duration: _parseDuration(track.duration),      
      artUri: _artUriFor(track),
      extras: {
        'videoId': track.id,
      },
    );
  }

  static Uri? _artUriFor(Track track) {
    final local = DownloadService.instance.coverPathOf(track.id);
    if (local != null) return Uri.file(local);
    return track.imageUrl.isEmpty ? null : Uri.tryParse(track.imageUrl);
  }

  static Duration _parseDuration(String duration) {
    final parts = duration.split(':');
    if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]) ?? 0;
      final seconds = int.tryParse(parts[1]) ?? 0;
      return Duration(minutes: minutes, seconds: seconds);
    }
    return Duration.zero;
  }

  Future<void> dispose() {
    _watchdogTimer?.cancel();
    return _player.dispose();
  }
}
