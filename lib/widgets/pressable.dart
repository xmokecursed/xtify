import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../desktop/desktop_scope.dart';
import '../theme/app_theme.dart';

class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;

  final Duration debounce;
  final double focusRadius;
  final bool hoverTint;
  final bool autofocus;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
    this.haptic = false,
    this.debounce = const Duration(milliseconds: 350),
    this.focusRadius = 12,
    this.hoverTint = false,
    this.autofocus = false,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  bool _focused = false;
  bool _hovered = false;
  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  void _fire() {
    final callback = widget.onTap;
    if (callback == null) return;
    final now = DateTime.now();
    if (now.difference(_lastTap) < widget.debounce) return;
    _lastTap = now;
    if (widget.haptic) HapticFeedback.selectionClick();
    callback();
  }

  @override
  Widget build(BuildContext context) {
    final core = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap == null ? null : _fire,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      onSecondaryTap: isDesktopPlatform ? widget.onLongPress : null,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _down ? 0.85 : 1,
          duration: const Duration(milliseconds: 120),
          child: widget.child,
        ),
      ),
    );
    if (!isDesktopPlatform) return core;
    final radius = BorderRadius.circular(widget.focusRadius);
    return FocusableActionDetector(
      enabled: widget.onTap != null,
      autofocus: widget.autofocus,
      mouseCursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onShowFocusHighlight: (v) {
        if (mounted && _focused != v) setState(() => _focused = v);
      },
      onShowHoverHighlight: (v) {
        if (mounted && _hovered != v) setState(() => _hovered = v);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _fire();
            return null;
          },
        ),
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          color: widget.hoverTint && (_hovered || _focused)
              ? AppColors.highlight
              : null,
        ),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: radius,
            border: _focused ? Border.all(color: Colors.white, width: 2) : null,
          ),
          child: core,
        ),
      ),
    );
  }
}
