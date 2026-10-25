import 'package:flutter/material.dart';
import '../services/debug_log.dart';
import '../theme/app_theme.dart';

/// Small bug icon: copies the debug info to the clipboard.
class DebugInfoButton extends StatelessWidget {
  const DebugInfoButton({super.key});

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    return IconButton(
      tooltip: 'Copy debug info',
      icon: const Icon(Icons.bug_report_outlined, color: AppColors.textSecondary),
      onPressed: () async {
        await DebugLog.copy();
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(const SnackBar(
          content: Text('Debug info copied. Paste it in your bug report.'),
          duration: Duration(seconds: 3),
        ));
      },
    );
  }
}
