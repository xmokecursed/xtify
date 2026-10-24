import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import '../widgets/media_tile.dart';
import '../widgets/player_sheet.dart';

/// The songs the user lined up: reorder, remove, or tap one to play it now.
class QueueScreen extends StatelessWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = XtifyAudioHandler.instance;
    return ValueListenableBuilder<List<Track>>(
      valueListenable: handler.upNextQueue,
      builder: (context, queue, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Queue'),
            actions: [
              if (queue.isNotEmpty)
                TextButton(
                  onPressed: handler.clearUserQueue,
                  child: const Text('Clear'),
                ),
            ],
          ),
          body: Stack(
            children: [
              ReorderableListView.builder(
                padding: const EdgeInsets.only(bottom: 140),
                buildDefaultDragHandles: false,
                itemCount: queue.length,
                onReorderItem: (a, b) => handler.reorderQueue(a, b),
                header: const _NowPlaying(),
                footer: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screen, 20, AppSpacing.screen, 0),
                  child: Text(
                    queue.isEmpty
                        ? 'Your queue is empty. Use "Play next" or "Add to queue" on any song.\n'
                            'After the queue, playback continues with the playlist or automatic picks.'
                        : 'After the queue, playback continues with the playlist or automatic picks.',
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                  ),
                ),
                itemBuilder: (context, i) {
                  final t = queue[i];
                  return ListTile(
                    key: ValueKey('q-${t.id}'),
                    contentPadding: const EdgeInsets.only(left: AppSpacing.screen, right: 4),
                    leading: ArtImage(url: t.imageUrl, size: 48, radius: 8),
                    title: Text(t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    subtitle: Text(t.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    onTap: () => handler.playQueueItem(i),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.close, size: 20),
                          onPressed: () => handler.removeFromQueue(i),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Icon(Icons.drag_handle, color: Colors.white54),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const PlayerSheet(),
            ],
          ),
        );
      },
    );
  }
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<MediaItem?>(
      stream: XtifyAudioHandler.instance.mediaItem,
      builder: (context, _) {
        final t = XtifyAudioHandler.instance.currentTrack;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.screen, 8, AppSpacing.screen, 4),
              child: Text('Now playing',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
            ),
            if (t == null)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.screen, vertical: 12),
                child: Text('Nothing playing',
                    style: TextStyle(color: AppColors.textSecondary)),
              )
            else
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                leading: ArtImage(url: t.imageUrl, size: 52, radius: 8),
                title: Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                subtitle: Text(t.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                trailing: const Icon(Icons.graphic_eq, color: Colors.white),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(AppSpacing.screen, 12, AppSpacing.screen, 4),
              child: Text('Next in queue',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textSecondary)),
            ),
          ],
        );
      },
    );
  }
}
