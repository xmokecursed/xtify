import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/audio_service.dart';
import '../services/download_service.dart';
import '../services/lyrics_service.dart';
import '../utils/image_cache.dart';

enum LyricsPhase { idle, loading, ready }

class LyricsController extends ChangeNotifier {
  LyricsController({required this.follow});

  final bool follow;
  StreamSubscription<MediaItem?>? _sub;
  StreamSubscription<String>? _storedSub;
  Timer? _delay;
  LyricsQuery? _query;
  LyricsPhase _phase = LyricsPhase.idle;
  LyricsResult? _result;
  Color _tint = _hashTint('');
  String _title = '';
  String _artist = '';
  int _token = 0;
  bool _first = true;
  bool _disposed = false;

  LyricsPhase get phase => _phase;
  LyricsResult? get result => _result;
  LyricsQuery? get query => _query;
  Color get tint => _tint;
  String get title => _title;
  String get artist => _artist;

  void start() {
    _sub ??= XtifyAudioHandler.instance.mediaItem.listen(_onItem);
    _storedSub ??= LyricsService.instance.onStored.listen((id) {
      if (id == _query?.id) _showCached();
    });
  }

  void _onItem(MediaItem? item) {
    if (_disposed || item?.id == _query?.id) return;
    _delay?.cancel();
    _token++;
    _result = null;
    _phase = LyricsPhase.idle;
    if (item == null) {
      _query = null;
      _title = '';
      _artist = '';
      _tint = _hashTint('');
      notifyListeners();
      return;
    }
    _query = LyricsQuery(
      id: item.id,
      title: item.title,
      artist: item.artist ?? '',
      seconds: item.duration?.inSeconds ?? 0,
    );
    _title = item.title;
    _artist = item.artist ?? '';
    _tint = _hashTint(item.id);
    if (follow) {
      _phase = LyricsPhase.loading;
    } else {
      final known = LyricsService.instance.peekNow(item.id);
      if (known != null &&
          (known.status == LyricsStatus.found ||
              known.status == LyricsStatus.instrumental)) {
        _result = known;
        _phase = LyricsPhase.ready;
      }
    }
    notifyListeners();
    _loadTint(item.id, item.artUri?.toString() ?? '');
    if (follow) {
      if (_first) {
        _run(false);
      } else {
        _delay = Timer(const Duration(milliseconds: 700), () => _run(false));
      }
    } else {
      _showCached();
    }
    _first = false;
  }

  Future<void> request({bool force = false}) async {
    if (_query == null || _phase == LyricsPhase.loading) return;
    await _run(force);
  }

  Future<void> _run(bool force) async {
    final query = _query;
    if (query == null) return;
    _delay?.cancel();
    final token = ++_token;
    _phase = LyricsPhase.loading;
    notifyListeners();
    final out = await LyricsService.instance.load(query, force: force);
    if (_disposed || token != _token) return;
    _result = out;
    _phase = LyricsPhase.ready;
    notifyListeners();
  }

  Future<void> _showCached() async {
    final query = _query;
    if (query == null || follow || _phase != LyricsPhase.idle) return;
    final token = _token;
    final cached = await LyricsService.instance.peek(query.id);
    if (_disposed || token != _token || _phase != LyricsPhase.idle) return;
    if (cached == null ||
        (cached.status != LyricsStatus.found &&
            cached.status != LyricsStatus.instrumental)) {
      return;
    }
    _result = cached;
    _phase = LyricsPhase.ready;
    notifyListeners();
  }

  Future<void> _loadTint(String id, String url) async {
    final color = await _coverTint(url);
    if (_disposed || color == null || _query?.id != id) return;
    _tint = color;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _delay?.cancel();
    _sub?.cancel();
    _storedSub?.cancel();
    super.dispose();
  }
}

Color _hashTint(String id) {
  final seed = id.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0x7fffffff);
  return HSLColor.fromAHSL(1, (seed % 360).toDouble(), 0.3, 0.3).toColor();
}

ImageProvider _artSource(String url) {
  if (url.startsWith('file://')) return FileImage(File.fromUri(Uri.parse(url)));
  final local = DownloadService.instance.coverFor(url);
  if (local != null) return FileImage(File(local));
  return CachedNetworkImageProvider(url, cacheManager: XtifyImageCache.instance);
}

Future<Color?> _coverTint(String url) async {
  if (url.isEmpty) return null;
  final done = Completer<Color?>();
  final stream =
      ResizeImage(_artSource(url), width: 32).resolve(const ImageConfiguration());
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) async {
      try {
        final data = await info.image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final avg = data == null
            ? null
            : _average(data, info.image.width, info.image.height);
        if (!done.isCompleted) done.complete(avg == null ? null : _shade(avg));
      } catch (_) {
        if (!done.isCompleted) done.complete(null);
      } finally {
        stream.removeListener(listener);
      }
    },
    onError: (Object error, StackTrace? trace) {
      stream.removeListener(listener);
      if (!done.isCompleted) done.complete(null);
    },
  );
  stream.addListener(listener);
  return done.future.timeout(const Duration(seconds: 8), onTimeout: () => null);
}

Color? _average(ByteData data, int width, int height) {
  if (width < 4 || height < 4) return null;
  final x0 = (width * 0.3).floor();
  final x1 = (width * 0.7).ceil();
  final y0 = (height * 0.2).floor();
  final y1 = (height * 0.8).ceil();
  var r = 0;
  var g = 0;
  var b = 0;
  var n = 0;
  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * width + x) * 4;
      if (i + 3 >= data.lengthInBytes || data.getUint8(i + 3) < 200) continue;
      r += data.getUint8(i);
      g += data.getUint8(i + 1);
      b += data.getUint8(i + 2);
      n++;
    }
  }
  if (n == 0) return null;
  return Color.fromARGB(255, r ~/ n, g ~/ n, b ~/ n);
}

Color _shade(Color color) {
  final hsl = HSLColor.fromColor(color);
  final saturation = math.min(0.55, math.max(0.2, hsl.saturation * 0.85));
  final lightness = math.min(0.38, math.max(0.26, hsl.lightness));
  return hsl.withSaturation(saturation).withLightness(lightness).toColor();
}
