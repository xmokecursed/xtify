import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Big title at the top of a tab.
class ScreenHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const ScreenHeader({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 24, AppSpacing.screen, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 36,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.2,
              color: Colors.white,
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 40),
              child: Text(
                subtitle!,
                style: const TextStyle(fontSize: 15, color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// Section title with optional subtitle and a trailing widget.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const SectionHeader({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 0, AppSpacing.screen, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: Colors.white,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    // hanging indent: the subtitle sits further in than the title
                    padding: const EdgeInsets.only(top: 3, left: 28),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One section of a tab: header plus content, with consistent spacing.
class SectionSliver extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  const SectionSliver({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.section),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(title: title, subtitle: subtitle, trailing: trailing),
            child,
          ],
        ),
      ),
    );
  }
}

/// Horizontal list whose first and last item line up with the screen padding.
class HList extends StatelessWidget {
  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  static const double _drop = 22;

  const HList({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height + _drop,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        // more room on the left than the right
        padding: const EdgeInsets.only(left: AppSpacing.screen + 8, right: 8),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.gap),
        // every second tile sits lower, so the row zigzags
        itemBuilder: (context, i) => Padding(
          padding: EdgeInsets.only(top: i.isOdd ? _drop : 0),
          child: itemBuilder(context, i),
        ),
      ),
    );
  }
}

/// Centered gray message (or spinner) for empty sections.
class EmptyHint extends StatelessWidget {
  final String text;
  final bool loading;

  const EmptyHint({super.key, required this.text, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
      child: SizedBox(
        height: 96,
        width: double.infinity,
        child: Center(
          child: loading
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
                )
              : Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
                ),
        ),
      ),
    );
  }
}
