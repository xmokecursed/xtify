import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import '../services/audio_service.dart';
import '../services/download_service.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_widgets.dart';
import '../widgets/player_sheet.dart';
import '../widgets/playlist_sheets.dart';
import '../widgets/track_row.dart';

class PlaylistScreen extends StatefulWidget {
  final String playlistId;
  const PlaylistScreen({super.key, required this.playlistId});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

enum _Sort { custom, recent, title, artist }

class _PlaylistScreenState extends State<PlaylistScreen> {
  _Sort _sort = _Sort.custom;
  String _query = '';
  final TextEditingController _filterCtl = TextEditingController();

  String get playlistId => widget.playlistId;

  @override
  void dispose() {
    _filterCtl.dispose();
    super.dispose();
  }

  /// The songs after the filter and sort. Custom order (no filter) is the playlist itself.
  List<Track> _shown(List<Track> all) {
    final q = _query.trim().toLowerCase();
    var list = q.isEmpty
        ? [...all]
        : all
            .where((t) =>
                t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q))
            .toList();
    switch (_sort) {
      case _Sort.custom:
        break;
      case _Sort.recent:
        list = list.reversed.toList(); // songs are added at the end
      case _Sort.title:
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case _Sort.artist:
        list.sort((a, b) {
          final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          return c != 0 ? c : a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
    }
    return list;
  }

  static String _sortLabel(_Sort s) => switch (s) {
        _Sort.custom => 'Custom order',
        _Sort.recent => 'Recently added',
        _Sort.title => 'Title A–Z',
        _Sort.artist => 'Artist A–Z',
      };

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

  void _play(BuildContext context, List<Track> tracks, {int start = 0, bool shuffle = false}) {
    XtifyAudioHandler.instance
        .playPlaylist(tracks, startIndex: start, shuffle: shuffle)
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
        final isDownloads = p.id == PlaylistService.downloadsId;
        final shown = _shown(p.tracks);
        final filtering = _query.trim().isNotEmpty || _sort != _Sort.custom;

        Widget row(BuildContext context, Track t, int i) {
          return Dismissible(
            key: ValueKey('${p.id}-${t.id}'),
            direction: DismissDirection.endToStart,
            // in Downloads, swiping also deletes the saved file
            onDismissed: (_) {
              if (isDownloads) {
                DownloadService.instance.remove(t.id);
                return;
              }
              final at = p.tracks.indexWhere((x) => x.id == t.id);
              PlaylistService.instance.removeTrack(p.id, t.id);
              // the saved file of a download cannot come back, so no Undo there
              final m = ScaffoldMessenger.of(context);
              m.hideCurrentSnackBar();
              m.showSnackBar(SnackBar(
                content: Text('Removed "${t.title}"'),
                duration: const Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'Undo',
                  onPressed: () => PlaylistService.instance
                      .insertTrack(p.id, t, at < 0 ? 0 : at),
                ),
              ));
            },
            background: Container(
              color: AppColors.card,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: AppSpacing.screen),
              child: const Icon(Icons.delete_outline),
            ),
            child: TrackRow(
              track: t,
              onTap: () => _play(context, shown, start: i),
              showDownload: !isDownloads,
              showMore: false,
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(p.title),
            actions: [
              if (isDownloads)
                IconButton(
                  tooltip: 'Download folder',
                  icon: const Icon(Icons.folder_outlined),
                  onPressed: () => showDownloadFolderSheet(context),
                )
              else if (!isFavourites)
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
                  ? Column(
                      children: [
                        if (isDownloads) ...const [DownloadFolderTile(), DownloadQueueSection()],
                        Expanded(
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                isFavourites
                                    ? 'No favourites yet.\nTap the heart on any song to save it here.'
                                    : isDownloads
                                        ? 'No downloads yet.\nTap the download icon on any song to save it here.'
                                        : 'No songs yet.\nOpen the menu on any song to add it here.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontSize: 15, color: AppColors.textSecondary),
                              ),
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      children: [
                        if (isDownloads) const DownloadFolderTile(),
                        if (isDownloads) const DownloadQueueSection(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.screen, 8, AppSpacing.screen, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  p.tracks.length == 1
                                      ? '1 song'
                                      : '${p.tracks.length} songs',
                                  style: const TextStyle(
                                      fontSize: 13, color: AppColors.textSecondary),
                                ),
                              ),
                              Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      onPressed: () => _play(context, shown),
                                      icon: const Icon(Icons.play_arrow_rounded),
                                      label: const Text('Play'),
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.gap),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => _play(context, shown, shuffle: true),
                                      icon: const Icon(Icons.shuffle_rounded),
                                      label: const Text('Shuffle'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _filterCtl,
                                      onChanged: (v) => setState(() => _query = v),
                                      textInputAction: TextInputAction.search,
                                      style: const TextStyle(fontSize: 15),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        hintText: 'Filter this playlist',
                                        hintStyle: const TextStyle(
                                            color: AppColors.textSecondary),
                                        prefixIcon: const Icon(Icons.search_rounded,
                                            size: 20, color: AppColors.textSecondary),
                                        suffixIcon: _query.isEmpty
                                            ? null
                                            : IconButton(
                                                icon: const Icon(Icons.close_rounded,
                                                    size: 18),
                                                onPressed: () {
                                                  _filterCtl.clear();
                                                  setState(() => _query = '');
                                                },
                                              ),
                                        filled: true,
                                        fillColor: AppColors.card,
                                        contentPadding:
                                            const EdgeInsets.symmetric(vertical: 12),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(14),
                                          borderSide: BorderSide.none,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.gap),
                                  PopupMenuButton<_Sort>(
                                    tooltip: 'Sort',
                                    initialValue: _sort,
                                    onSelected: (v) => setState(() => _sort = v),
                                    itemBuilder: (_) => [
                                      for (final s in _Sort.values)
                                        PopupMenuItem(
                                          value: s,
                                          child: Text(_sortLabel(s)),
                                        ),
                                    ],
                                    child: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: AppColors.card,
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Icon(
                                        Icons.sort_rounded,
                                        color: _sort == _Sort.custom
                                            ? AppColors.textSecondary
                                            : Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: shown.isEmpty
                              ? const Center(
                                  child: Text(
                                    'No matching songs',
                                    style: TextStyle(
                                        fontSize: 15, color: AppColors.textSecondary),
                                  ),
                                )
                              : filtering
                                  ? ListView.builder(
                                      padding: const EdgeInsets.only(bottom: 140),
                                      itemCount: shown.length,
                                      itemBuilder: (context, i) =>
                                          row(context, shown[i], i),
                                    )
                                  : ReorderableListView.builder(
                                      padding: const EdgeInsets.only(bottom: 140),
                                      itemCount: p.tracks.length,
                                      onReorderItem: (a, b) =>
                                          PlaylistService.instance.reorder(p.id, a, b),
                                      itemBuilder: (context, i) =>
                                          row(context, p.tracks[i], i),
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