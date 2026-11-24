import 'package:flutter/material.dart';
import '../services/vault.dart';
import '../theme/app_theme.dart';

// Shown only when Xtify could not unlock its saved data, so nobody has to
// wonder where their playlists went. Nothing is deleted when this happens.
class StorageBanner extends StatefulWidget {
  const StorageBanner({super.key});

  @override
  State<StorageBanner> createState() => _StorageBannerState();
}

class _StorageBannerState extends State<StorageBanner> {
  bool _handled = false;

  static String _explain(Vault vault) {
    final text = StringBuffer(
      'Xtify could not unlock your saved playlists, history and settings on this device. '
      'Nothing was deleted or changed, and Xtify tries again every time it starts. '
      'Until it works, changes you make are not saved.',
    );
    if (vault.canStartFresh) {
      text
        ..write('\n\nThe key that locks your data is not available any more. ')
        ..write('This can happen after the key storage of the phone was reset, or on Windows after ')
        ..write('a password reset, a reinstall of Windows, or when Xtify was opened as a different user. ')
        ..write('If you opened it as a different user, close it and open it normally instead.')
        ..write('\n\nIf the key is really gone, nobody can read the old data any more. ')
        ..write('Start fresh moves it into a separate folder (it is not deleted) ')
        ..write('and begins with an empty library.');
    }
    text.write('\n\nReason: ${vault.summary}');
    return text.toString();
  }

  Future<void> _open() async {
    final vault = Vault.instance;
    final wantsFresh = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('Saved data is locked'),
        content: SingleChildScrollView(
          child: Text(_explain(vault), style: const TextStyle(fontSize: 14, height: 1.4)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Close'),
          ),
          if (vault.canStartFresh)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Start fresh'),
            ),
        ],
      ),
    );
    if (wantsFresh != true || !mounted) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('Start fresh?'),
        content: const Text(
          'Your playlists, history, settings and YouTube sign-in will not be available in '
          'Xtify any more. The old files are kept in a separate folder, not deleted, but '
          'they cannot be read without the lost key. Xtify starts with an empty library '
          'the next time it opens.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Start fresh'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final done = await vault.startFresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          done
              ? 'Done. Close Xtify and open it again to start fresh.'
              : 'Could not move the old data aside. Nothing was changed.',
        ),
      ),
    );
    if (done) setState(() => _handled = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_handled || Vault.instance.state != VaultState.locked) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 8, AppSpacing.screen, 8),
      child: Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: _open,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.hairline),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline, size: 20, color: Colors.white70),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Saved data is locked. Nothing was deleted.',
                    style: TextStyle(fontSize: 13, color: Colors.white),
                  ),
                ),
                SizedBox(width: 8),
                Text(
                  'Details',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    decoration: TextDecoration.underline,
                    decorationColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
