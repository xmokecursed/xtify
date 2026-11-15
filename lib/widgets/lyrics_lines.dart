import 'dart:async';
import 'dart:math' as math;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../services/audio_service.dart';
import '../services/lyrics_service.dart';

Widget _edgeFade({required Widget child, required bool both}) {
  return ShaderMask(
    blendMode: BlendMode.dstIn,
    shaderCallback: (rect) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: both
          ? const [Color(0x00FFFFFF), Colors.white, Colors.white, Color(0x00FFFFFF)]
          : const [Colors.white, Colors.white, Color(0x00FFFFFF)],
      stops: both ? const [0.0, 0.06, 0.84, 1.0] : const [0.0, 0.74, 1.0],
    ).createShader(rect),
    child: child,
  );
}

Widget _still(BuildContext context, {required bool compact, required Widget child}) {
  if (!compact) return child;
  return ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: child,
  );
}

class SyncedLyrics extends StatefulWidget {
  final List<LyricLine> lines;
  final bool compact;
  final Widget? footer;

  const SyncedLyrics({
    super.key,
    required this.lines,
    this.compact = false,
    this.footer,
  });

  @override
  State<SyncedLyrics> createState() => _SyncedLyricsState();
}

class _SyncedLyricsState extends State<SyncedLyrics> {
  static const Duration _lookahead = Duration(milliseconds: 250);
  static const Duration _pause = Duration(seconds: 4);

  late final List<GlobalKey> _keys =
      List<GlobalKey>.generate(widget.lines.length, (_) => GlobalKey());
  final ScrollController _scroll = ScrollController();
  StreamSubscription<Duration>? _sub;
  DateTime _manualUntil = DateTime.fromMillisecondsSinceEpoch(0);
  int _active = -1;
  bool _settled = false;
  bool _driving = false;

  @override
  void initState() {
    super.initState();
    _sub = AudioService.position.listen(_onPosition);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  int _indexAt(Duration position) {
    final lines = widget.lines;
    final target = position + _lookahead;
    var low = 0;
    var high = lines.length - 1;
    var found = -1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (lines[mid].at <= target) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  void _onPosition(Duration position) {
    final next = _indexAt(position);
    if (next == _active || !mounted) return;
    setState(() => _active = next);
    _reveal();
  }

  void _reveal() {
    if (_active < 0 || DateTime.now().isBefore(_manualUntil)) return;
    final animate = _settled || _active < 3;
    _settled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _active < 0 || !_scroll.hasClients) return;
      final box = _keys[_active].currentContext?.findRenderObject();
      if (box == null || !box.attached) return;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) return;
      final wanted = viewport.getOffsetToReveal(box, 0.32).offset;
      final position = _scroll.position;
      final target = math.min(
        position.maxScrollExtent,
        math.max(position.minScrollExtent, wanted),
      );
      _driving = true;
      if (animate) {
        _scroll
            .animateTo(
              target,
              duration: const Duration(milliseconds: 520),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
          _driving = false;
        });
      } else {
        _scroll.jumpTo(target);
        _driving = false;
      }
    });
  }

  Widget _line(int index, double size, double gap) {
    final line = widget.lines[index];
    final alpha = index == _active ? 1.0 : (index < _active ? 0.72 : 0.34);
    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: gap),
      child: AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        style: TextStyle(
          color: Colors.white.withValues(alpha: alpha),
          fontSize: size,
          fontWeight: FontWeight.w800,
          height: 1.2,
          letterSpacing: -0.4,
        ),
        child: Text(line.text.isEmpty ? '♪' : line.text),
      ),
    );
    if (widget.compact) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => XtifyAudioHandler.instance.seek(line.at),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: row),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final lines = widget.lines;
    final footer = widget.footer;
    return LayoutBuilder(
      builder: (context, box) {
        final side = compact ? 18.0 : 24.0;
        final bottom = box.maxHeight.isFinite ? box.maxHeight * 0.6 : 200.0;
        final list = NotificationListener<ScrollNotification>(
          onNotification: (_) {
            if (!_driving) _manualUntil = DateTime.now().add(_pause);
            return false;
          },
          child: _still(
            context,
            compact: compact,
            child: SingleChildScrollView(
              controller: _scroll,
              physics: compact ? const NeverScrollableScrollPhysics() : null,
              padding: EdgeInsets.fromLTRB(side, compact ? 18 : 28, side, bottom),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < lines.length; i++)
                    KeyedSubtree(
                      key: _keys[i],
                      child: _line(i, compact ? 21 : 28, compact ? 7 : 11),
                    ),
                  if (footer != null) footer,
                ],
              ),
            ),
          ),
        );
        return _edgeFade(child: list, both: !compact);
      },
    );
  }
}

class PlainLyrics extends StatelessWidget {
  final List<String> lines;
  final bool compact;
  final Widget? footer;

  const PlainLyrics({
    super.key,
    required this.lines,
    this.compact = false,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final footer = this.footer;
    final side = compact ? 18.0 : 24.0;
    final body = _still(
      context,
      compact: compact,
      child: SingleChildScrollView(
        physics: compact ? const NeverScrollableScrollPhysics() : null,
        padding: EdgeInsets.fromLTRB(side, compact ? 18 : 28, side, compact ? 28 : 160),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              lines.join('\n'),
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: compact ? 18 : 24,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            if (footer != null) footer,
          ],
        ),
      ),
    );
    return _edgeFade(child: body, both: !compact);
  }
}
