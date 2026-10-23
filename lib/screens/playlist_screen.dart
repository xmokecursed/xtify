import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../services/audio_service.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import '../widgets/player_sheet.dart';
import '../widgets/playlist_sheets.dart';
import '../widgets/track_row.dart';

class PlaylistScreen extends StatelessWidget {
  final String playlistId;
  const PlaylistScreen({super.key, required this.playlistId});

  Future<void> _menu(BuildContext context, Playlist p, String action) async {
    if (action == 'rename') {
      final name = await promptPlaylistName(context, initial: p.title);
      if (name != null) await PlaylistService.instance.rename(p.id, name);
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          surfaceTintColor: Colors.transparent,
          title: Text('Delete "${p.title}"?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
          ],
        ),
      );
      if (ok == true) {
        if (context.mounted) Navigator.pop(context);
        await PlaylistService.instance.delete(p.id);
      }
    }
  }

  void _play(BuildContext context, Playlist p, {int start = 0, bool shuffle = false}) {
    XtifyAudioHandler.instance
        .playPlaylist(p.tracks, startIndex: start, shuffle: shuffle)
        .catchError((Object e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start playback')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Playlist>>(
      valueListenable: PlaylistService.instance.playlists,
      builder: (context, all, _) {
        final p = all.where((x) => x.id == playlistId).firstOrNull;
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Playlist not found')),
          );
        }
        final isFavourites = p.id == PlaylistService.favouritesId;
        return Scaffold(
          appBar: AppBar(
            title: Text(p.title),
            actions: [
              if (!isFavourites)
                PopupMenuButton<String>(
                  onSelected: (v) => _menu(context, p, v),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
                  ],
                ),
            ],
          ),
          body: Stack(
            children: [
              p.tracks.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          isFavourites
                              ? 'No favourites yet.\nTap the heart on any song to save it here.'
                              : 'No songs yet.\nOpen the menu on any song to add it here.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 15, color: AppColors.textSecondary),
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.screen, 8, AppSpacing.screen, 12),
                          child: Row(
                            children: [
                              FilledButton.icon(
                                onPressed: () => _play(context, p),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Play'),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
                                onPressed: () => _play(context, p, shuffle: true),
                                icon: const Icon(Icons.shuffle),
                                label: const Text('Shuffle'),
                              ),
                              const Spacer(),
                              Text(
                                '${p.tracks.length} songs',
                                style: const TextStyle(
                                    fontSize: 13, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ReorderableListView.builder(
                            padding: const EdgeInsets.only(bottom: 140),
                            itemCount: p.tracks.length,
                            onReorderItem: (a, b) =>
                                PlaylistService.instance.reorder(p.id, a, b),
                            itemBuilder: (context, i) {
                              final t = p.tracks[i];
                              return Dismissible(
                                key: ValueKey('${p.id}-${t.id}'),
                                direction: DismissDirection.endToStart,
                                onDismissed: (_) =>
                                    PlaylistService.instance.removeTrack(p.id, t.id),
                                background: Container(
                                  color: AppColors.card,
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(right: AppSpacing.screen),
                                  child: const Icon(Icons.delete_outline),
                                ),
                                child: TrackRow(
                                  track: t,
                                  onTap: () => _play(context, p, start: i),
                                  showMore: false,
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
              const PlayerSheet(),
            ],
          ),
        );
      },
    );
  }
}
