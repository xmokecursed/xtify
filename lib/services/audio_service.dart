import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/track_model.dart';
import '../services/audio_url_resolver.dart';
import '../services/download_service.dart';
import '../services/history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auto_queue_service.dart';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';

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
        skipToNext().catchError((Object e) {
          debugPrint('auto-advance failed: $e');
        });
      }
    });
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
        if (idx == null || idx >= _player.sequence.length) return;
        final item = _player.sequence[idx].tag as MediaItem?;
        final track = item == null ? null : _tracksById[item.id];
        if (track == null) return;
        AudioUrlResolver.clearCache(track.id);
        if (idx == _player.currentIndex) {
          debugPrint('song failed to open, retrying: ${track.title}');
          playTrack(track, userInitiated: false, keepContext: true).catchError((Object e) {
            debugPrint('retry failed: $e');
          });
        } else {
          _player.removeAudioSourceAt(idx).catchError((Object e) {});
          _nextQueued = false; // try another candidate
        }
      } catch (e) {
        debugPrint('error recovery failed: $e');
      }
    });
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
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _savePosition(_player.position);
  }

  @override
  Future<void> seek(Duration position) async {
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
    if (!keepContext) _context = const [];
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

    final n = AudioUrlResolver.strategyCount;
    for (var k = 0; k < n; k++) {
      if (token != _playToken) return;
      final idx = (AudioUrlResolver.preferredStrategy + k) % n;
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
      throw Exception('Could not play this track. ${errors.join(' | ')}');
    }
  }

  Future<bool> _tryPlay(ResolvedAudioUrl r, MediaItem item, int token,
      List<String> errors, String label, {Duration? start}) async {
    _settingSource = true;
    try {
      final sw = Stopwatch()..start();
      await _player.setAudioSource(AudioSource.uri(
        Uri.parse(r.url),
        headers: r.headers.isEmpty ? null : r.headers,
        tag: item,
      ), initialPosition: start);
      debugPrint('setAudioSource ($label) took ${sw.elapsedMilliseconds}ms');
      if (token != _playToken) return false;
      _sourceLoaded = true;
      _player.play();
      debugPrint('playing via $label');
      return true;
    } catch (e) {
      errors.add('$label: ${_short(e)}');
      debugPrint('play attempt failed ($label): ${_short(e)}');
      return false;
    } finally {
      _settingSource = false;
    }
  }

  // ---------------- auto queue ----------------  
  /// Plays [tracks] in order (or shuffled). When they run out, auto-queue continues.
  Future<void> playPlaylist(List<Track> tracks,
      {int startIndex = 0, bool shuffle = false}) async {
    final playable = tracks.where((t) => t.isPlayable).toList();
    if (playable.isEmpty) throw Exception('No playable songs in this playlist');
    final startTrack = (startIndex >= 0 &&
            startIndex < tracks.length &&
            tracks[startIndex].isPlayable)
        ? tracks[startIndex]
        : playable.first;
    final list = [...playable];
    if (shuffle) {
      list.removeWhere((t) => t.id == startTrack.id);
      list.shuffle();
      list.insert(0, startTrack);
    }
    _context = list;
    await playTrack(startTrack, keepContext: true);
  }

  /// Next song: the playlist's next one, otherwise whatever auto-queue picks.
  Future<Track?> _nextTrack(Track seed) async {
    if (_context.isNotEmpty) {
      final i = _context.indexWhere((t) => t.id == seed.id);
      if (i >= 0 && i + 1 < _context.length) return _context[i + 1];
    }
    final next = await _autoQueue.nextFor(seed);
    if (next != null) return next;
    // never go silent: fall back to something already played
    final others = HistoryService.instance.tracks.value.where((t) => t.id != seed.id).toList()..shuffle();
    return others.firstOrNull;
  }

  void _started(Track t) {    
    HistoryService.instance.add(t);    
    // While a playlist still has songs left, it decides what is next
    final i = _context.indexWhere((x) => x.id == t.id);
    final playlistHasNext = i >= 0 && i + 1 < _context.length;
    if (!playlistHasNext) {
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
    _preparingNext = true;    
    findingNext.value = true;
    _prepareAttempts++;    
    _lastPrepareAt = DateTime.now();    
    final token = _playToken;    
    final sw = Stopwatch()..start();    
    try {      
      final next = await _nextTrack(seed);      
      if (next == null) {        
        debugPrint('auto-queue: no candidate for "${seed.title}"');        
        return;      
      }      
      if (token != _playToken) return;      
      final resolved = await _resolveForQueue(next.id);      
      if (resolved == null || token != _playToken) return;      
      final item = createMediaItem(next);      
      _tracksById[next.id] = next;      
      _queuedUrls[next.id] = resolved;      
      await _player.addAudioSource(AudioSource.uri(        
        Uri.parse(resolved.url),        
        headers: resolved.headers.isEmpty ? null : resolved.headers,        
        tag: item,      ));      
      if (token != _playToken) return;      
      _nextQueued = true;      
      _queue.add([..._queue.value, item]);      
      debugPrint('auto-queue: "${next.title}" ready in ${sw.elapsedMilliseconds}ms');    
    } catch (e) {      
      debugPrint('auto-queue failed: ${_short(e)}');    
    } finally {      
      if (token == _playToken) {        
        _preparingNext = false;        
        findingNext.value = false;      
      }  
  }  
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
    // let a song the user is waiting for go first
    for (var i = 0; i < 80 && AudioUrlResolver.isBusy; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    final n = AudioUrlResolver.strategyCount;    
    for (var k = 0; k < 2; k++) {      
      final idx = (AudioUrlResolver.preferredStrategy + k) % n;      
      try {        
        return await AudioUrlResolver().resolve(videoId, strategyIndex: idx);      
      } catch (e) {        
        debugPrint('queue resolve failed (${AudioUrlResolver.strategyLabel(idx)}): ${_short(e)}');      
      }    }    
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
    _mediaItem.add(item);    
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
      artUri: track.imageUrl.isEmpty ? null : Uri.tryParse(track.imageUrl),
      extras: {
        'videoId': track.id, // Store YouTube video ID for later resolution
      },
    );
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
    return _player.dispose();
  }
}
