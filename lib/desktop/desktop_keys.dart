import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/audio_service.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import 'app_nav.dart';
import 'desktop_scope.dart';

class DesktopKeyboard extends StatelessWidget {
  final Widget child;

  const DesktopKeyboard({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      debugLabel: 'Xtify shortcuts',
      onKeyEvent: (node, event) => _handleKey(context, event),
      child: child,
    );
  }
}

bool _isTyping() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool _spaceActivatesFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (SpaceTogglesPlayback.at(ctx)) return false;
  return Actions.maybeFind<ActivateIntent>(ctx) != null;
}

KeyEventResult _handleKey(BuildContext context, KeyEvent event) {
  if (event is KeyUpEvent) return KeyEventResult.ignored;
  final nav = AppNav.instance;
  if (!nav.topIsPage) return KeyEventResult.ignored;

  final hardware = HardwareKeyboard.instance;
  final ctrl = hardware.isControlPressed || hardware.isMetaPressed;
  final shift = hardware.isShiftPressed;
  final alt = hardware.isAltPressed;
  final key = event.logicalKey;
  final first = event is KeyDownEvent;
  final typing = _isTyping();
  final h = XtifyAudioHandler.instance;

  KeyEventResult done(VoidCallback action, {bool repeatable = false}) {
    if (first || repeatable) action();
    return KeyEventResult.handled;
  }

  if (ctrl && !alt &&
      (key == LogicalKeyboardKey.keyK ||
          key == LogicalKeyboardKey.keyL ||
          key == LogicalKeyboardKey.keyF)) {
    return done(nav.focusSearch);
  }
  if (ctrl && !alt && !shift) {
    if (key == LogicalKeyboardKey.digit1) return done(() => nav.goTab(AppNav.homeTab));
    if (key == LogicalKeyboardKey.digit2) return done(() => nav.goTab(AppNav.searchTab));
    if (key == LogicalKeyboardKey.digit3) return done(() => nav.goTab(AppNav.libraryTab));
    if (key == LogicalKeyboardKey.slash) return done(() => showShortcutsHelp(context));
  }
  if (key == LogicalKeyboardKey.f1) return done(() => showShortcutsHelp(context));
  if (key == LogicalKeyboardKey.f5) return done(nav.refreshFeed);
  if (alt && !ctrl && key == LogicalKeyboardKey.arrowLeft) return done(nav.back);

  if (key == LogicalKeyboardKey.mediaPlayPause) return done(h.togglePlayPause);
  if (key == LogicalKeyboardKey.mediaTrackNext) return done(h.skipToNext);
  if (key == LogicalKeyboardKey.mediaTrackPrevious) return done(h.skipToPrevious);

  if (typing) {
    if (key == LogicalKeyboardKey.escape) {
      return done(() => FocusManager.instance.primaryFocus?.unfocus());
    }
    if (key == LogicalKeyboardKey.arrowDown &&
        !ctrl && !shift && !alt &&
        identical(FocusManager.instance.primaryFocus, nav.searchFocus)) {
      if (!first) return KeyEventResult.handled;
      return nav.searchFocus.focusInDirection(TraversalDirection.down)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  if (!ctrl && !alt && !shift) {
    if (key == LogicalKeyboardKey.space) {
      if (_spaceActivatesFocused()) return KeyEventResult.ignored;
      return done(h.togglePlayPause);
    }
    if (key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.backspace) {
      if (!nav.canGoBack) return KeyEventResult.ignored;
      return done(nav.back);
    }
    if (key == LogicalKeyboardKey.slash) return done(nav.focusSearch);
    if (key == LogicalKeyboardKey.keyM) return done(h.toggleMute);
    if (key == LogicalKeyboardKey.keyQ) return done(nav.toggleQueue);
    if (key == LogicalKeyboardKey.keyN) return done(nav.toggleNowPlaying);
  }
  if (first && event.character == '?') {
    showShortcutsHelp(context);
    return KeyEventResult.handled;
  }

  if (ctrl && !alt && !shift) {
    if (key == LogicalKeyboardKey.arrowRight) return done(h.skipToNext);
    if (key == LogicalKeyboardKey.arrowLeft) return done(h.skipToPrevious);
    if (key == LogicalKeyboardKey.arrowUp) {
      return done(() => h.setVolume(h.volume.value + 0.05), repeatable: true);
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      return done(() => h.setVolume(h.volume.value - 0.05), repeatable: true);
    }
    if (key == LogicalKeyboardKey.keyS) return done(() => h.setShuffle(!h.shuffleOn.value));
    if (key == LogicalKeyboardKey.keyR) return done(h.cycleRepeat);
    if (key == LogicalKeyboardKey.keyD) {
      return done(() {
        final t = h.currentTrack;
        if (t != null) PlaylistService.instance.toggleFavourite(t);
      });
    }
  }
  if (shift && !ctrl && !alt) {
    if (key == LogicalKeyboardKey.arrowRight) {
      return done(() => h.seekBy(const Duration(seconds: 10)), repeatable: true);
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      return done(() => h.seekBy(const Duration(seconds: -10)), repeatable: true);
    }
  }
  return KeyEventResult.ignored;
}

Future<void> showShortcutsHelp(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _ShortcutsDialog(),
  );
}

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  static const List<(String, List<(String, String)>)> _groups = [
    (
      'Playback',
      [
        ('Play / pause', 'Space'),
        ('Next song', 'Ctrl + →'),
        ('Previous song', 'Ctrl + ←'),
        ('Seek 10 s forward / back', 'Shift + → / ←'),
        ('Volume up / down', 'Ctrl + ↑ / ↓'),
        ('Mute', 'M'),
        ('Shuffle', 'Ctrl + S'),
        ('Repeat', 'Ctrl + R'),
        ('Like this song', 'Ctrl + D'),
      ],
    ),
    (
      'Navigate',
      [
        ('Search', 'Ctrl + K  or  /'),
        ('Home / Search / Library', 'Ctrl + 1 / 2 / 3'),
        ('Move between items', 'Arrow keys  or  Tab'),
        ('Play or open the focused item', 'Enter'),
        ('Song options', 'Menu key  or  Shift + F10'),
        ('Back', 'Esc  or  Alt + ←'),
        ('Queue', 'Q'),
        ('Now playing panel', 'N'),
        ('This list', '?  or  F1'),
      ],
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Keyboard shortcuts',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (title, rows) in _groups) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 8, bottom: 6),
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                        for (final (label, keys) in rows)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    label,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: AppColors.card,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Text(
                                    keys,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  autofocus: true,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
