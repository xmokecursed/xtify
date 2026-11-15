import 'package:flutter/material.dart';
import '../desktop/app_nav.dart';
import '../desktop/desktop_scope.dart';
import '../services/lyrics_service.dart';
import '../theme/app_theme.dart';
import 'lyrics_controller.dart';
import 'lyrics_lines.dart';
import 'pressable.dart';

const TextStyle _noteStyle = TextStyle(
  color: AppColors.textSecondary,
  fontSize: 14,
  height: 1.35,
);

class LyricsSection extends StatefulWidget {
  final double titleSize;

  const LyricsSection({super.key, this.titleSize = 17});

  @override
  State<LyricsSection> createState() => _LyricsSectionState();
}

class _LyricsSectionState extends State<LyricsSection> {
  final LyricsController _controller = LyricsController(follow: false);

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 40,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Lyrics',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: widget.titleSize,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  final result = _controller.result;
                  if (result == null || result.status != LyricsStatus.found) {
                    return const SizedBox.shrink();
                  }
                  return IconButton(
                    tooltip: isDesktopPlatform ? 'Full screen (L)' : 'Full screen',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                    icon: const Icon(
                      Icons.fullscreen_rounded,
                      size: 24,
                      color: AppColors.textSecondary,
                    ),
                    onPressed: AppNav.instance.openLyrics,
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        LyricsBody(
          controller: _controller,
          compact: true,
          onOpen: AppNav.instance.openLyrics,
        ),
      ],
    );
  }
}

class LyricsBody extends StatelessWidget {
  final LyricsController controller;
  final bool compact;
  final VoidCallback? onOpen;

  const LyricsBody({
    super.key,
    required this.controller,
    this.compact = false,
    this.onOpen,
  });

  bool get _found =>
      controller.phase == LyricsPhase.ready &&
      controller.result?.status == LyricsStatus.found;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => compact ? _card() : _page(),
    );
  }

  Widget _lyrics({Widget? footer}) {
    final result = controller.result!;
    if (result.isSynced) {
      return SyncedLyrics(
        key: ValueKey<String?>(controller.query?.id),
        lines: result.synced,
        compact: compact,
        footer: footer,
      );
    }
    return PlainLyrics(
      key: ValueKey<String?>(controller.query?.id),
      lines: result.plain,
      compact: compact,
      footer: footer,
    );
  }

  Widget _card() {
    final found = _found;
    final Widget inner = found
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: _lyrics(),
          )
        : _message();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSize(
          duration: AppMotion.medium,
          curve: AppMotion.curve,
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: found ? 340 : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOut,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: found
                    ? controller.tint
                    : AppColors.card.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: found ? null : Border.all(color: AppColors.hairline),
              ),
              child: inner,
            ),
          ),
        ),
        if (found)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Lyrics from lrclib.net',
              style: TextStyle(color: AppColors.textTertiary, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _page() {
    if (_found) {
      return _lyrics(
        footer: const Padding(
          padding: EdgeInsets.only(top: 16),
          child: Text(
            'Lyrics from lrclib.net',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: _message(),
      ),
    );
  }

  Widget _frame(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  Widget _note(String text) => _frame([Text(text, style: _noteStyle)]);

  Widget _ask() {
    return _frame([
      const Text('Lyrics are only loaded when you ask for them.', style: _noteStyle),
      const SizedBox(height: 14),
      _Pill(label: 'Show lyrics', filled: true, onTap: controller.request),
    ]);
  }

  Widget _retry(String text, String label, {bool force = false}) {
    return _frame([
      Text(text, style: _noteStyle),
      const SizedBox(height: 14),
      _Pill(
        label: label,
        filled: false,
        onTap: () => controller.request(force: force),
      ),
    ]);
  }

  Widget _loading() {
    return _frame([
      const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
          SizedBox(width: 12),
          Expanded(child: Text('Looking for lyrics…', style: _noteStyle)),
        ],
      ),
    ]);
  }

  String _busyText(Duration? wait) {
    if (wait == null) return 'The lyrics service is busy right now.';
    final seconds = wait.inSeconds + 1;
    final span = seconds < 90 ? '$seconds seconds' : '${(seconds / 60).ceil()} minutes';
    return 'The lyrics service is busy. Try again in about $span.';
  }

  Widget _message() {
    if (controller.query == null) return _note('Play a song to see its lyrics.');
    final result = controller.result;
    switch (controller.phase) {
      case LyricsPhase.idle:
        return _ask();
      case LyricsPhase.loading:
        return _loading();
      case LyricsPhase.ready:
        if (result == null) return _ask();
        return switch (result.status) {
          LyricsStatus.found => _ask(),
          LyricsStatus.notFound =>
            _retry('No lyrics found for this song.', 'Search again', force: true),
          LyricsStatus.instrumental => _note('This song is instrumental.'),
          LyricsStatus.offline => _retry("You're offline.", 'Try again'),
          LyricsStatus.busy => _retry(_busyText(result.wait), 'Try again'),
          LyricsStatus.failed => _retry("Couldn't load lyrics.", 'Try again'),
        };
    }
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;

  const _Pill({required this.label, required this.filled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      focusRadius: 20,
      debounce: const Duration(milliseconds: 250),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: filled ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: filled ? null : Border.all(color: Colors.white38),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: filled ? Colors.black : Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
