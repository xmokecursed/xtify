import 'dart:io' show Platform;

import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../widgets/layout.dart';
import 'hover_builder.dart';

enum WindowEdge {
  top,
  topLeft,
  topRight,
  left,
  right,
  bottom,
  bottomLeft,
  bottomRight,
}

class WindowChrome {
  WindowChrome._();
  static final WindowChrome instance = WindowChrome._();

  static const MethodChannel _channel = MethodChannel('xtify/window');

  final ValueNotifier<bool> active = ValueNotifier<bool>(false);
  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);

  Future<void> init() async {
    if (!Platform.isWindows) return;
    _channel.setMethodCallHandler(_onCall);
    try {
      final value = await _channel.invokeMethod<bool>('isMaximized');
      maximized.value = value ?? false;
      active.value = true;
    } on MissingPluginException {
      active.value = false;
    } on PlatformException catch (e) {
      debugPrint('Window controls unavailable: ${e.message}');
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'maximized') maximized.value = call.arguments == true;
    return null;
  }

  Future<void> minimize() => _send('minimize');

  Future<void> toggleMaximize() => _send('toggleMaximize');

  Future<void> close() => _send('close');

  Future<void> startDrag() => _send('startDrag');

  Future<void> startResize(WindowEdge edge) => _send('startResize', edge.index);

  Future<void> _send(String method, [Object? arguments]) async {
    if (!active.value) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      active.value = false;
    } on PlatformException catch (e) {
      debugPrint('Window $method failed: ${e.message}');
    }
  }
}

class WindowDragArea extends StatelessWidget {
  final Widget? child;

  const WindowDragArea({super.key, this.child});

  @override
  Widget build(BuildContext context) {
    final chrome = WindowChrome.instance;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => chrome.startDrag(),
      onDoubleTap: chrome.toggleMaximize,
      child: child,
    );
  }
}

class WindowControls extends StatelessWidget {
  static const double buttonWidth = 46;
  static const double height = 32;
  static const double width = buttonWidth * 3;

  const WindowControls({super.key});

  @override
  Widget build(BuildContext context) {
    final chrome = WindowChrome.instance;
    return Material(
      type: MaterialType.transparency,
      child: SizedBox(
        height: height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CaptionButton(
              icon: Icons.remove_rounded,
              label: 'Minimize',
              onTap: chrome.minimize,
            ),
            ValueListenableBuilder<bool>(
              valueListenable: chrome.maximized,
              builder: (context, maximized, _) => _CaptionButton(
                icon: maximized
                    ? Icons.filter_none_rounded
                    : Icons.crop_square_rounded,
                label: maximized ? 'Restore' : 'Maximize',
                onTap: chrome.toggleMaximize,
              ),
            ),
            _CaptionButton(
              icon: Icons.close_rounded,
              label: 'Close',
              onTap: chrome.close,
              danger: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _CaptionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _CaptionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: HoverBuilder(
        builder: (context, hovered) {
          final Color background = !hovered
              ? Colors.transparent
              : danger
                  ? const Color(0xFFE81123)
                  : const Color(0x1FFFFFFF);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: ColoredBox(
              color: background,
              child: SizedBox(
                width: WindowControls.buttonWidth,
                height: WindowControls.height,
                child: Icon(icon, size: 16, color: Colors.white),
              ),
            ),
          );
        },
      ),
    );
  }
}

class WindowTitleBar extends StatelessWidget {
  static const double height = WindowControls.height;

  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: AppColors.black,
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            Expanded(
              child: WindowDragArea(
                child: Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Row(
                    children: [
                      XtifyLogo(size: 18),
                      SizedBox(width: 8),
                      Text(
                        'Xtify',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(width: WindowControls.width),
          ],
        ),
      ),
    );
  }
}

class WindowFrame extends StatelessWidget {
  final bool titleBar;
  final Widget child;

  const WindowFrame({super.key, required this.titleBar, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: WindowChrome.instance.active,
      child: child,
      builder: (context, active, content) {
        if (!active) return content!;
        return Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                titleBar ? const WindowTitleBar() : const SizedBox.shrink(),
                Expanded(child: content!),
              ],
            ),
            const Positioned.fill(child: _ResizeZones()),
            const Positioned(top: 0, right: 0, child: WindowControls()),
          ],
        );
      },
    );
  }
}

class _ResizeZones extends StatelessWidget {
  static const double _thickness = 5;
  static const double _corner = 10;

  const _ResizeZones();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: WindowChrome.instance.maximized,
      builder: (context, maximized, _) {
        if (maximized) return const SizedBox.shrink();
        return const Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: _corner,
              height: _thickness,
              child: _ResizeZone(
                edge: WindowEdge.topLeft,
                cursor: SystemMouseCursors.resizeUpLeftDownRight,
              ),
            ),
            Positioned(
              left: _corner,
              right: WindowControls.width,
              top: 0,
              height: _thickness,
              child: _ResizeZone(
                edge: WindowEdge.top,
                cursor: SystemMouseCursors.resizeUpDown,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ResizeZone extends StatelessWidget {
  final WindowEdge edge;
  final MouseCursor cursor;

  const _ResizeZone({required this.edge, required this.cursor});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (event.buttons == kPrimaryMouseButton) {
            WindowChrome.instance.startResize(edge);
          }
        },
      ),
    );
  }
}
