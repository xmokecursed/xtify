import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';

/// Download icon for one song: download -> progress ring -> check mark.
class DownloadButton extends StatelessWidget {
  final Track track;
  final double size;

  const DownloadButton({super.key, required this.track, this.size = 22});

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    final messenger = ScaffoldMessenger.of(context);

    void say(String text, {SnackBarAction? action}) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(text),
        action: action,
      ));
    }

    return ListenableBuilder(
      listenable: Listenable.merge([svc.items, svc.tasks]),
      builder: (context, _) {
        if (svc.isDownloaded(track.id)) {
          return IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Downloaded',
            icon: Icon(Icons.download_done, size: size, color: Colors.greenAccent),
            onPressed: () => say(
              'Saved on this phone',
              action: SnackBarAction(
                label: 'Remove',
                onPressed: () => svc.remove(track.id),
              ),
            ),
          );
        }
        final task = svc.tasks.value[track.id];
        if (task != null && task.status != DownloadStatus.failed) {
          final active = task.status == DownloadStatus.active && task.progress > 0;
          return IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Cancel download',
            icon: SizedBox(
              width: size - 2,
              height: size - 2,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                value: active ? task.progress : null,
                color: Colors.white,
              ),
            ),
            onPressed: () => svc.cancel(track.id),
          );
        }
        if (task != null) {
          return IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Download failed, tap to retry',
            icon: Icon(Icons.error_outline, size: size, color: Colors.orangeAccent),
            onPressed: () {
              svc.enqueue(track);
              say('Retrying "${track.title}"');
            },
          );
        }
        return IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: 'Download',
          icon: Icon(Icons.download_outlined, size: size),
          color: Colors.white,
          onPressed: () {
            svc.enqueue(track);
            say('Downloading "${track.title}"');
          },
        );
      },
    );
  }
}

/// Row showing where downloads are saved; tap to change it.
class DownloadFolderTile extends StatelessWidget {
  const DownloadFolderTile({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    return ValueListenableBuilder<String>(
      valueListenable: svc.folder,
      builder: (context, path, _) => ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
        leading: const Icon(Icons.folder_outlined),
        title: ValueListenableBuilder<bool>(
          valueListenable: svc.customFolder,
          builder: (_, custom, _) => Text(
            custom ? 'Download folder' : 'Download folder (app storage)',
            style: const TextStyle(fontSize: 14),
          ),
        ),
        subtitle: Text(
          path,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showDownloadFolderSheet(context),
      ),
    );
  }
}

/// Lets the user pick a download folder or go back to the app's own one.
Future<void> showDownloadFolderSheet(BuildContext context) {
  final messenger = ScaffoldMessenger.of(context);
  final svc = DownloadService.instance;

  Future<void> choose(BuildContext sheetContext) async {
    Navigator.pop(sheetContext);
    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath();
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not open the folder picker')));
      return;
    }
    if (picked == null) return; // cancelled
    final err = await svc.setFolder(picked);
    messenger.showSnackBar(SnackBar(
      content: Text(err ?? 'New downloads will be saved to $picked'),
    ));
  }

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.screen, 20, AppSpacing.screen, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Download folder',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.screen, 0, AppSpacing.screen, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ValueListenableBuilder<String>(
                valueListenable: svc.folder,
                builder: (_, p, _) => Text(
                  'Now: $p\nSongs you already downloaded stay where they are.',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
            ),
          ),
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
            leading: const Icon(Icons.folder_open),
            title: const Text('Choose a folder'),
            onTap: () => choose(sheetContext),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: svc.customFolder,
            builder: (_, custom, _) => custom
                ? ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                    leading: const Icon(Icons.restore),
                    title: const Text('Use the default (app storage)'),
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      await svc.setFolder(null);
                      messenger.showSnackBar(const SnackBar(
                          content: Text('New downloads will be saved in app storage')));
                    },
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
