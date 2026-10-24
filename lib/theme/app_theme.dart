import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

class AppColors {
  static const Color black = Color(0xFF000000);
  static const Color surface = Color(0xFF0D0D0D);
  static const Color card = Color(0xFF171717);
  static const Color border = Color(0xFF282828);
  static const Color textSecondary = Color(0xFF8E8E8E);

  /// Black and white only: "accent" is just white.
  static const Color accent = Colors.white;
}

/// Uneven corners: big top-left and bottom-right, nearly square on the others.
BorderRadius asymRadius(double r) => BorderRadius.only(
      topLeft: Radius.circular(r * 2.2),
      topRight: Radius.circular(r * 0.35),
      bottomRight: Radius.circular(r * 2.2),
      bottomLeft: Radius.circular(r * 0.35),
    );

class AppSpacing {
  /// Left and right padding on every screen.
  static const double screen = 20;

  /// Vertical gap between sections.
  static const double section = 28;

  /// Gap between items in a row.
  static const double gap = 14;
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: Colors.white,
    onPrimary: Colors.black,
    secondary: AppColors.textSecondary,
    onSecondary: Colors.black,
    surface: AppColors.surface,
    onSurface: Colors.white,
    error: Color(0xFFD0D0D6),
    onError: Colors.black,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.black,
    canvasColor: AppColors.surface,
    iconTheme: const IconThemeData(color: Colors.white),
    dividerColor: AppColors.border,
    highlightColor: Colors.transparent,
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: ZoomPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    }),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: AppColors.black,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.white.withValues(alpha: 0.14),
      labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
      height: 64,
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
            color: s.contains(WidgetState.selected)
                ? AppColors.accent
                : AppColors.textSecondary,
          )),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: s.contains(WidgetState.selected)
                ? Colors.white
                : AppColors.textSecondary,
          )),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.black,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      foregroundColor: Colors.white,
      titleTextStyle: TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Colors.white),
      bodyMedium: TextStyle(color: AppColors.textSecondary),
      titleLarge: TextStyle(
        color: Colors.white,
        fontSize: 20,
        fontWeight: FontWeight.bold,
        letterSpacing: -0.4,
      ),
      titleMedium: TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: asymRadius(11)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: asymRadius(11)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Colors.white),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(36),
          topRight: Radius.circular(8),
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.card,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      actionTextColor: Colors.white,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.card,
      surfaceTintColor: Colors.transparent,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
    listTileTheme: const ListTileThemeData(
      iconColor: Colors.white,
      textColor: Colors.white,
    ),
  );
}
