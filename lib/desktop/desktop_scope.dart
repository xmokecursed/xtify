import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

final bool isDesktopPlatform =
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

const double kWideMinWidth = 900;
const double kWideMinHeight = 520;

class DesktopScope extends InheritedWidget {
  final bool wide;

  const DesktopScope({super.key, required this.wide, required super.child});

  static bool isWide(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DesktopScope>();
    return scope?.wide ?? false;
  }

  @override
  bool updateShouldNotify(DesktopScope oldWidget) => wide != oldWidget.wide;
}

class SpaceTogglesPlayback extends InheritedWidget {
  const SpaceTogglesPlayback({super.key, required super.child});

  static bool at(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SpaceTogglesPlayback>() != null;

  @override
  bool updateShouldNotify(SpaceTogglesPlayback oldWidget) => false;
}
