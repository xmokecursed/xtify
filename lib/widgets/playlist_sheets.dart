import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import '../screens/queue_screen.dart';
import '../services/artist_mix_service.dart';
import '../services/audio_service.dart';
import '../services/download_service.dart';
import '../services/history_service.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import 'media_tile.dart';
import 'youtube_link.dart';

Future<String?> promptPlaylistName(BuildContext context, {String initial = ''}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(initial: initial),
  );
}

class _NameDialog extends StatefulWidget {
  final String initial;
  const _NameDialog({required this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _done() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      title: Text(widget.initial.isEmpty ? 'New playlist' : 'Rename playlist'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _done(),
        decoration: const InputDecoration(hintText: 'Playlist name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _done,
          child: Text(widget.initial.isEmpty ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}


Future<void> showAddToPlaylistSheet(BuildContext context, Track track) async {
  final messenger = ScaffoldMessenger.of(context);
  final lists = PlaylistService.instance.userPlaylists;

  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));

  if (lists.isEmpty) {
    final name = await promptPlaylistName(context);
    if (name == null) return;
    final p = await PlaylistService.instance.create(name);
    await PlaylistService.instance.addTrack(p.id, track);
    say('Added to ${p.title}');
    return;
  }

  if (lists.length == 1) {
    final p = lists.first;
    final added = await PlaylistService.instance.addTrack(p.id, track);
    say(added ? 'Added to ${p.title}' : 'Already in ${p.title}');
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.6,
          ),
          child: ValueListenableBuilder<List<Playlist>>(
            valueListenable: PlaylistService.instance.playlists,
            builder: (context, _, _) {
              final current = PlaylistService.instance.userPlaylists;
              return ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(AppSpacing.screen, 4, AppSpacing.screen, 8),
                    child: Text(
                      'Add to playlist',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                    leading: const Icon(Icons.add),
                    title: const Text('New playlist'),
                    onTap: () async {
                      final name = await promptPlaylistName(sheetContext);
                      if (name == null) return;
                      final p = await PlaylistService.instance.create(name);
                      await PlaylistService.instance.addTrack(p.id, track);
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                      say('Added to ${p.title}');
                    },
                  ),
                  for (final p in current)
                    ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                      leading: const Icon(Icons.queue_music),
                      title: Text(p.title),
                      subtitle: Text(
                        '${p.tracks.length} songs',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                      trailing: p.tracks.any((t) => t.id == track.id)
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () async {
                        final added =
                            await PlaylistService.instance.addTrack(p.id, track);
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                        say(added ? 'Added to ${p.title}' : 'Already in ${p.title}');
                      },
                    ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

Future<void> showTrackOptions(BuildContext context, Track track) {
  final messenger = ScaffoldMessenger.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true, 
    builder: (sheetContext) {
      return SafeArea(
        child: SingleChildScrollView(
         child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.screen, 20, AppSpacing.screen, 12),
              child: Row(
                children: [
                  ArtImage(url: track.imageUrl, size: 52, radius: 8),
                  const SizedBox(width: AppSpacing.gap),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(),
            ValueListenableBuilder<List<Playlist>>(
              valueListenable: PlaylistService.instance.playlists,
              builder: (context, _, _) {
                final fav = PlaylistService.instance.isFavourite(track.id);
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                  leading: Icon(fav ? Icons.favorite : Icons.favorite_border),
                  title: Text(fav ? 'Remove from Favourites' : 'Add to Favourites'),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final nowFav = await PlaylistService.instance.toggleFavourite(track);
                    messenger.showSnackBar(SnackBar(
                      content: Text(nowFav
                          ? 'Added to Favourites'
                          : 'Removed from Favourites'),
                    ));
                  },
                );
              },
            ),
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
              leading: const Icon(Icons.playlist_play),
              title: const Text('Play next'),
              onTap: () {
                Navigator.pop(sheetContext);
                _queueAction(context, messenger, track, next: true);
              },
            ),
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to queue'),
              onTap: () {
                Navigator.pop(sheetContext);
                _queueAction(context, messenger, track, next: false);
              },
            ),
            ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to playlist'),
              onTap: () {
                Navigator.pop(sheetContext);
                if (context.mounted) showAddToPlaylistSheet(context, track);
              },
            ),
            if (track.isPlayable)
              ListTile(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                leading: const Icon(Icons.open_in_new),
                title: const Text('Open on YouTube'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  if (context.mounted) showYoutubeLink(context, track);
                },
              ),
            ValueListenableBuilder<List<Track>>(
              valueListenable: HistoryService.instance.tracks,
              builder: (context, _, _) => HistoryService.instance.contains(track.id)
                  ? ListTile(
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                      leading: const Icon(Icons.history_toggle_off),
                      title: const Text('Remove from history'),
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        final at = HistoryService.instance.tracks.value
                            .indexWhere((t) => t.id == track.id);
                        await HistoryService.instance.remove(track.id);
                        await ArtistMixService.instance.forget(track.id);
                        messenger.hideCurrentSnackBar();
                        messenger.showSnackBar(SnackBar(
                          content: const Text('Removed from history'),
                          duration: const Duration(seconds: 5),
                          action: SnackBarAction(
                            label: 'Undo',
                            onPressed: () => HistoryService.instance
                                .restore(track, at < 0 ? 0 : at),
                          ),
                        ));
                      },
                    )
                  : const SizedBox.shrink(),
            ),
            ListenableBuilder(
              listenable: Listenable.merge([
                DownloadService.instance.items,
                DownloadService.instance.tasks,
              ]),
              builder: (context, _) {
                final svc = DownloadService.instance;
                final saved = svc.isDownloaded(track.id);
                final busy = svc.tasks.value[track.id]?.status == DownloadStatus.queued ||
                    svc.tasks.value[track.id]?.status == DownloadStatus.active;
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                  leading: Icon(saved ? Icons.delete_outline : Icons.download_outlined),
                  title: Text(saved
                      ? 'Remove download'
                      : busy
                          ? 'Downloading… (tap to cancel)'
                          : 'Download'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    if (saved) {
                      svc.remove(track.id);
                      messenger.showSnackBar(
                          const SnackBar(content: Text('Download removed')));
                    } else if (busy) {
                      svc.cancel(track.id);
                    } else {
                      svc.enqueue(track);
                      messenger.showSnackBar(SnackBar(
                          content: Text('Downloading "${track.title}"')));
                    }
                  },
                );
              },
            ),
            const SizedBox(height: 8),
          ],
         ),
        ),
      );
    },
  );
}
Future<void> _queueAction(BuildContext context, ScaffoldMessengerState messenger, Track track,
    {required bool next}) async {
  bool done;
  try {
    done = next
        ? await XtifyAudioHandler.instance.playNext(track)
        : await XtifyAudioHandler.instance.addToQueue(track);
  } catch (e) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not start playback')));
    return;
  }
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(done
        ? (next ? 'Will play next' : 'Added to queue')
        : 'Already playing or in the queue'),
    action: done
        ? SnackBarAction(
            label: 'View',
            onPressed: () {
              if (context.mounted) {
                Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const QueueScreen()));
              }
            },
          )
        : null,
  ));
}
