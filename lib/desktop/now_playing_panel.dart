import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import '../widgets/media_tile.dart';
import '../widgets/player_sheet.dart';
import '../widgets/pressable.dart';
import 'app_nav.dart';

class NowPlayingPanel extends StatelessWidget {
  const NowPlayingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return Container(
      width: 340,
      margin: const EdgeInsets.only(left: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.hairline),
      ),
      child: StreamBuilder<MediaItem?>(
        stream: h.mediaItem,
        initialData: h.mediaItem.valueOrNull,
        builder: (context, snap) {
          final item = snap.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Now playing',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close (N)',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: AppNav.instance.toggleNowPlaying,
                  ),
                ],
              ),
              if (item == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text(
                      'Nothing playing',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 14),
                    ),
                  ),
                )
              else ...[
                const SizedBox(height: 8),
                LayoutBuilder(
                  builder: (context, c) => ArtImage(
                    url: item.artUri?.toString() ?? '',
                    size: c.maxWidth,
                    radius: 14,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.artist ?? 'Unknown Artist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 15),
                ),
                const SizedBox(height: 16),
                PlayerActionRow(onOpenQueue: AppNav.instance.toggleQueue),
                const SizedBox(height: 24),
                const Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Up next',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    AutoQueueGear(),
                  ],
                ),
                const AutoQueueNotice(),
                const SizedBox(height: 8),
                const _UpNext(),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _UpNext extends StatelessWidget {
  const _UpNext();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return StreamBuilder<List<MediaItem>>(
      stream: h.queue,
      initialData: h.queue.valueOrNull,
      builder: (context, snapshot) {
        final queue = snapshot.data ?? const <MediaItem>[];
        final upcoming = queue.length > 1 ? queue.sublist(1) : const <MediaItem>[];
        return ValueListenableBuilder<bool>(
          valueListenable: h.findingNext,
          builder: (context, finding, _) {
            if (upcoming.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  finding ? 'Finding the next song…' : 'The next song is picked automatically',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
                ),
              );
            }
            return Column(
              children: [
                for (var i = 0; i < upcoming.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Pressable(
                      focusRadius: 8,
                      hoverTint: true,
                      onTap: () => h.skipToQueueItem(i + 1),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          children: [
                            ArtImage(
                              url: upcoming[i].artUri?.toString() ?? '',
                              size: 44,
                              radius: 8,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    upcoming[i].title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    upcoming[i].artist ?? 'Unknown Artist',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
