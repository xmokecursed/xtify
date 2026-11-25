import 'package:flutter/material.dart';
import '../services/vault.dart';
import '../theme/app_theme.dart';

// Shown only when Xtify left some saved data untouched: its key could not
// unlock it, a newer version of Xtify wrote it, or it could not be read.
// Nothing is deleted in any of these cases, so nobody has to wonder where
// their playlists went.
class StorageBanner extends StatefulWidget {
  const StorageBanner({super.key});

  @override
  State<StorageBanner> createState() => _StorageBannerState();
}

class _StorageBannerState extends State<StorageBanner> {
  // After Start fresh the old data is already set aside, and there is nothing
  // left to explain until Xtify is opened again.
  bool get _locked =>
      !Vault.instance.startedFresh && Vault.instance.state == VaultState.locked;

  static String _explain(Vault vault, List<String> notes, {required bool locked}) {
    final text = StringBuffer();
    if (locked) {
      text.write(
        'Xtify could not unlock your saved playlists, history and settings on this device. '
        'Nothing was deleted or changed, and Xtify tries again every time it starts. '
        'If you went back to an older version of Xtify, installing the newer one again '
        'unlocks everything. Until it works, changes you make are not saved.',
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
    }
    if (notes.isNotEmpty) {
      if (text.isNotEmpty) text.write('\n\n');
      text.write(notes.join('\n\n'));
    }
    return text.toString();
  }

  Future<void> _open() async {
    final vault = Vault.instance;
    final locked = _locked;
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: Text(locked ? 'Saved data is locked' : 'Saved data was left untouched'),
        content: SingleChildScrollView(
          child: Text(
            _explain(vault, vault.notices.value, locked: locked),
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'close'),
            child: const Text('Close'),
          ),
          if (vault.newerItems.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'aside'),
              child: const Text('Set aside'),
            ),
          if (vault.canStartFresh)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'fresh'),
              child: const Text('Start fresh'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'fresh') await _startFresh();
    if (!mounted) return;
    if (choice == 'aside') await _setAside();
  }

  Future<void> _startFresh() async {
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
    final done = await Vault.instance.startFresh();
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
    if (done) setState(() {});
  }

  Future<void> _setAside() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        title: const Text('Set the newer data aside?'),
        content: const Text(
          'The saved data that a newer version of Xtify wrote moves into a separate folder '
          '(it is not deleted), and this version starts with an empty copy of it. '
          'If you can, update Xtify instead: the newer version then uses that data as it is.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Set aside'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    final done = await Vault.instance.setAsideNewer();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          done
              ? 'Done. The newer data was moved into a separate folder.'
              : 'Could not move it. Nothing was changed.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: Vault.instance.notices,
      builder: (context, notes, _) {
        final locked = _locked;
        if (!locked && notes.isEmpty) return const SizedBox.shrink();
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
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 20, color: Colors.white70),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        locked
                            ? 'Saved data is locked. Nothing was deleted.'
                            : 'Some saved data was left untouched.',
                        style: const TextStyle(fontSize: 13, color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
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
      },
    );
  }
}
