import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/track_model.dart';
import '../services/audio_url_resolver.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';
import '../services/history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auto_queue_service.dart';
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
  // Playlist being played in order; empty = auto-queue decides what is next.
  List<Track> _context = const [];
  List<Track> _ctxOriginal = const []; // the playlist's own order (shuffle turns off back to it)
  String? _ctxCursorId; // last playlist song played: the playlist resumes after queued songs

  // Songs the user lined up ("Play next" / "Add to queue"). They play before the
  // playlist or the auto-picks. The song already loaded as "next" is shown at the front.
  List<Track> _userQueue = [];
  Track? _preloaded; // the song already added to the player as "next"
  bool _preloadedFromUser = false;
  int _prepareEpoch = 0; // bumped whenever what comes next changes
  DateTime _lastSongStart = DateTime.fromMillisecondsSinceEpoch(0);
  final ValueNotifier<List<Track>> upNextQueue = ValueNotifier<List<Track>>(const []);
  final ValueNotifier<bool> shuffleOn = ValueNotifier<bool>(false);
  final ValueNotifier<XtifyRepeat> repeat = ValueNotifier<XtifyRepeat>(XtifyRepeat.off);

  Track? get currentTrack => _currentTrack;
  bool _nextQueued = false;
  bool _preparingNext = false;
  bool _settingSource = false;
  int _prepareAttempts = 0;
  DateTime _lastPrepareAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _prepareLead = Duration(hours: 24);
  final ValueNotifier<bool> findingNext = ValueNotifier<bool>(false);
  bool _sourceLoaded = false; // false right after start-up: last song is shown, not loaded
  Duration _restoredPosition = Duration.zero;
  DateTime _lastSaved = DateTime.fromMillisecondsSinceEpoch(0);

  XtifyAudioHandler() {
    _instance = this;
    _init().catchError((e) {
      if (bool.fromEnvironment('dart.vm.product') == false) {
        debugPrint('Audio handler initialization error: $e');
      }
    });

    // Handle duration updates
    _player.durationStream.listen((duration) {
      final current = _mediaItem.valueOrNull;
      if (current != null) {
        final updated = current.copyWith(duration: duration);
        _mediaItem.add(updated);
      }
    });

    // When the last queued song ends, move on (slow path if nothing was ready)
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        // A song cannot have ended seconds after it started: that "completed" is a leftover
        // of the previous song (it made the new song skip right away).
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
    // Start preparing the next song with 120 s left; gapless hand-off
    _player.positionStream.listen(_onPosition);
    _player.currentIndexStream.listen(_onIndexChanged);
    // Player errors: drop the bad cached URL and recover a queued song that failed
    _player.errorStream.listen((error) {
      debugPrint('Audio player error: $error');
      final current = _mediaItem.valueOrNull;
      final videoId = current?.extras?['videoId'] as String?;
      if (videoId != null && videoId.isNotEmpty) {
        AudioUrlResolver.clearCache(videoId);
      }
      if (_settingSource) return; // playTrack handles errors during its own load
      try {
        final idx = error.index;
        final cur = _player.currentIndex;
        if (idx == null || idx == cur) {
          // the song that is playing broke (expired link, network drop): reload it in place
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
        _nextQueued = false; // try another candidate
        _preloaded = null;
        _preloadedFromUser = false;
        _publishQueue();
      } catch (e) {
        debugPrint('error recovery failed: $e');
      }
    });
  }

  // ---------------- self-healing ----------------
  Timer? _watchdogTimer;
  bool _recovering = false;
  bool _gaveUp = false; // recovery stopped after repeated failures: wait for the user
  int _recoveryStreak = 0;
  DateTime _lastRecovery = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _wdPos = Duration.zero;
  DateTime _wdAt = DateTime.now();

  /// Reloads the current song at the same position (fresh link). Gives up after a few
  /// quick failures in a row so it can never loop. [force] = the user asked for it.
  Future<void> _recoverCurrent({Duration? at, bool force = false}) async {
    final t = _currentTrack;
    if (t == null || _recovering || !_sourceLoaded) return;
    final now = DateTime.now();
    _recoveryStreak = now.difference(_lastRecovery) < const Duration(seconds: 30)
        ? _recoveryStreak + 1
        : 0;
    if (!force && _recoveryStreak >= 3) {
      // say it once, and let the watchdog stay quiet until the user presses play
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

  /// Every 4 s: if audio should be playing but is stuck (frozen or buffering far too long), reload it.
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
    // Handle player events
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
      // first play after start-up: load the stream and jump to where we left off
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
      await _recoverCurrent(force: true); // the stream died: bring it back where it was
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
    _restoredPosition = position; // nothing loaded yet: just move the marker
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

  /// Shows the song played last time (paused, at the saved position) without loading audio.
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
      // Update the player's index directly
      return _player.seek(Duration.zero, index: index);
    }
    return Future.value();
  }

  bool _advancing = false;
  @override
  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext(); // pre-loaded: instant
      return;
    }
    // Nothing pre-loaded (tapped early, or preparing failed): slow path
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
    await playTrack(h[1], userInitiated: false); // h[0] is the current song
  }

  Future<void> clearQueue() {
    _queue.add(<MediaItem>[]);
    _mediaItem.add(null);
    return stop();
  }

  Future<double> getSpeed() => _player.speedStream.first;

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  /// Play a track: cached URL first, then each strategy until the
  /// player can actually open the stream.
  Future<void> playTrack(Track track,
      {bool userInitiated = true, bool keepContext = false, Duration? startAt}) async {
    final token = ++_playToken;
    _gaveUp = false; // a new attempt: the watchdog may watch again
    // a queued song that was loaded as "next" goes back to the front of the queue
    if (_preloaded != null && _preloadedFromUser) _userQueue = [_preloaded!, ..._userQueue];
    _preloaded = null;
    _preloadedFromUser = false;
    _prepareEpoch++;
    // playing a song that is also queued: it is not queued twice
    _userQueue = _userQueue.where((x) => x.id != track.id).toList();
    _publishQueue();
    final mediaItem = XtifyAudioHandler.createMediaItem(track);
    final videoId = (mediaItem.extras?['videoId'] as String?) ?? '';
    if (videoId.isEmpty) throw Exception('Missing video ID in media item');
    // Fresh playlist: forget anything queued for the previous song
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
      _autoQueue.startSession(track);
    } else {
      _autoQueue.advanced(track);
    }
    // The queue holds only the current song until the next one is ready
    _queue.add([mediaItem]);
    _mediaItem.add(mediaItem);

    final errors = <String>[];

    // A song saved on the phone plays from the file: instant, and works offline.
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

    // the direct lookup first (while it works), then yt-dlp, the way that worked last first
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

  // ---------------- auto queue ----------------  
  /// Plays [tracks] in order (or shuffled). When they run out, auto-queue continues.
  Future<void> playPlaylist(List<Track> tracks,
      {int startIndex = 0, bool shuffle = false}) async {
    // offline, only downloaded songs can play
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

  /// Position of [seed] in the playlist; a queued song that is not in the playlist
  /// counts as the last playlist song that played, so the playlist resumes after it.
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
        if (ok(_context[j])) return _context[j]; // back to the start (or the same song again)
      }
    }
    return null;
  }

  /// Next song: the user's queue first, then the playlist, otherwise whatever
  /// auto-queue picks (offline: another downloaded song).
  Future<Track?> _nextTrack(Track seed) async {
    if (_userQueue.isNotEmpty) return _userQueue.first; // peeked; taken once it is committed
    final offline = !ConnectivityService.instance.online.value;
    final inContext = _contextNext(seed, offline);
    if (inContext != null) return inContext;
    if (offline) {
      final others = DownloadService.instance.items.value.values
          .map((e) => e.track)
          .where((t) => t.id != seed.id)
          .toList()
        ..shuffle();
      return others.firstOrNull;
    }
    final next = await _autoQueue.nextFor(seed);
    if (next != null) return next;
    // Fall back only to another song by the SAME artist; never jump to an unrelated artist.
    final a = seed.artist.trim().toLowerCase();
    if (a.isEmpty) return null;
    final others = HistoryService.instance.tracks.value
        .where((t) => t.id != seed.id && t.artist.trim().toLowerCase() == a)
        .toList()
      ..shuffle();
    return others.firstOrNull;
  }

  /// Takes [t] off the front of the user's queue when it is the song that was picked from it.
  void _consumeUserHead(Track t) {
    if (_userQueue.isNotEmpty && _userQueue.first.id == t.id) {
      _userQueue = _userQueue.sublist(1);
      _publishQueue();
    }
  }

  void _started(Track t) {    
    HistoryService.instance.add(t);    
    // While a playlist still has songs left, it decides what is next
    if (_context.any((x) => x.id == t.id)) _ctxCursorId = t.id;
    final i = _ctxIndex(t);
    final playlistHasNext = i >= 0 &&
        (i + 1 < _context.length || repeat.value == XtifyRepeat.all);
    if (!playlistHasNext && _userQueue.isEmpty) {
      _autoQueue.warm(t); // Last.fm + backend search now, so the next song is picked early
    }  
  }  

  /// Runs on every position tick: start preparing when <= 120 s remain.  
  void _onPosition(Duration pos) {
    if (_sourceLoaded && DateTime.now().difference(_lastSaved) > const Duration(seconds: 5)) {
      _savePosition(pos);
    }
    if (_nextQueued || _preparingNext || _currentTrack == null) return;    
    final dur = _player.duration;    
    if (dur == null || dur == Duration.zero) return;    
    if (dur - pos > _prepareLead) return;    
    if (_prepareAttempts >= 6) return;    
    if (DateTime.now().difference(_lastPrepareAt) < Duration(seconds: 6 * (_prepareAttempts + 1))) return; // backs off    
    _prepareNext();  
  }  

  Future<void> _prepareNext() async {
    final seed = _currentTrack;
    if (seed == null || _preparingNext || _nextQueued) return;
    if (repeat.value == XtifyRepeat.one) return; // the same song plays again, nothing to load
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
      if (next.id == seed.id) return; // replay of the same song: handled when it ends
      if (stale()) return;
      final fromUser = _userQueue.isNotEmpty && _userQueue.first.id == next.id;
      final resolved = await _resolveForQueue(next.id);
      if (resolved == null || stale()) return;
      final item = createMediaItem(next);
      _tracksById[next.id] = next;
      _queuedUrls[next.id] = resolved;
      await _removeWaiting(); // nothing may be waiting here: never two songs queued
      await _player.addAudioSource(
        audioSourceFor(resolved.url, headers: resolved.headers, tag: item),
      );
      if (stale()) {
        // another song started, or what comes next changed, while this one loaded
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

  // ---------------- the user's queue, shuffle and repeat ----------------

  /// What the queue screen shows: the loaded "next" song (if it came from the
  /// queue) followed by the rest of the queue.
  void _publishQueue() {
    upNextQueue.value = [
      if (_preloadedFromUser && _preloaded != null) _preloaded!,
      ..._userQueue,
    ];
  }

  /// Removes every song waiting after the current one in the player.
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

  /// Unloads the song waiting as "next" so that what comes next can change.
  /// A queued song that was waiting goes back to the front of the queue.
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

  /// Puts [t] at the front of the queue. Returns false when it is the song playing now.
  /// With nothing playing, the song just starts.
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

  /// Puts [t] at the end of the queue. Returns false when it is playing or already queued.
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

  /// [newIndex] follows ReorderableListView.onReorderItem (already corrected for the removal).
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

  /// Plays a queued song right now; the songs before it stay queued.
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
    if (_context.isEmpty) return; // nothing to reorder: auto-queue picks anyway
    await _dropPreloaded();
    final cur = _currentTrack;
    final i = cur == null ? -1 : _ctxIndex(cur);
    if (on) {
      _ctxOriginal = [..._context];
      final head = i >= 0 ? _context.sublist(0, i + 1) : <Track>[];
      final tail = (i >= 0 ? _context.sublist(i + 1) : [..._context])..shuffle();
      _context = [...head, ...tail];
    } else if (_ctxOriginal.isNotEmpty) {
      _context = [..._ctxOriginal]; // back to the playlist's own order
    }
  }

  Future<void> cycleRepeat() async {
    final next = XtifyRepeat.values[(repeat.value.index + 1) % XtifyRepeat.values.length];
    repeat.value = next;
    await _dropPreloaded(); // what comes next may differ now (wrap-around / replay)
  }

  /// file:// source for a downloaded song, or null when it is not on the phone.
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
    // The direct lookup needs no yt-dlp, so it neither waits for it nor holds it up.
    if (AudioUrlResolver.canLookUpDirectly(videoId)) {
      try {
        return await AudioUrlResolver().resolve(videoId,
            strategyIndex: AudioUrlResolver.nativeIndex, background: true);
      } catch (e) {
        debugPrint('queue resolve failed (native): ${_short(e)}');
      }
    }
    // let a song the user is waiting for go first
    for (var i = 0; i < 80 && AudioUrlResolver.isBusy; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    // one try with the usual strategy: if it fails, the next attempt picks another candidate
    // (a second run of the same client only holds up the song the user may tap meanwhile)
    final idx = AudioUrlResolver.preferredStrategy % AudioUrlResolver.strategyCount;
    try {
      return await AudioUrlResolver().resolve(videoId, strategyIndex: idx, background: true);
    } catch (e) {
      debugPrint('queue resolve failed (${AudioUrlResolver.strategyLabel(idx)}): ${_short(e)}');
    }
    return null;
  }

  /// The player moved on to the pre-loaded song by itself.  
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

  // Create media item from track
  static MediaItem createMediaItem(Track track) {
    return MediaItem(
      id: track.id,
      album: track.album,
      title: track.title,
      artist: track.artist,
      duration: _parseDuration(track.duration),      
      artUri: _artUriFor(track),
      extras: {
        'videoId': track.id, // Store YouTube video ID for later resolution
      },
    );
  }

  /// A downloaded song's cover comes from the phone (works offline, also in the notification).
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
