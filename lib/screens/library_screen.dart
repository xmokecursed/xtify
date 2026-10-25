import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../services/history_service.dart';
import '../services/playlist_service.dart';
import '../widgets/debug_button.dart';
import '../widgets/layout.dart';
import '../widgets/media_tile.dart';
import '../widgets/offline_banner.dart';
import '../widgets/playlist_sheets.dart';
import 'artist_screen.dart';
import 'playlist_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  Future<void> _create(BuildContext context) async {
    final name = await promptPlaylistName(context);
    if (name == null) return;
    final p = await PlaylistService.instance.create(name);
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlaylistScreen(playlistId: p.id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: ScreenHeader(title: 'Library', trailing: DebugInfoButton()),
        ),
        const SliverToBoxAdapter(child: OfflineBanner()),
        SectionSliver(
          title: 'Playlists',
          trailing: TextButton.icon(
            onPressed: () => _create(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New'),
          ),
          child: ValueListenableBuilder<List<Playlist>>(
            valueListenable: PlaylistService.instance.playlists,
            builder: (context, lists, _) {
              if (lists.isEmpty) {
                return const EmptyHint(text: 'No playlists yet. Tap New to create one.');
              }
              return HList(
                height: 200,
                itemCount: lists.length,
                itemBuilder: (context, i) {
                  final p = lists[i];
                  return MediaTile(
                    title: p.title,
                    subtitle: '${p.tracks.length} songs',
                    imageUrl: p.imageUrl,
                    fallbackIcon: p.id == PlaylistService.favouritesId
                        ? Icons.favorite
                        : p.id == PlaylistService.downloadsId
                            ? Icons.download_done
                            : Icons.queue_music,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlaylistScreen(playlistId: p.id),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        SectionSliver(
          title: 'Artists',
          subtitle: 'The artists you listen to',
          child: ValueListenableBuilder<List<ArtistEntry>>(
            valueListenable: HistoryService.instance.artists,
            builder: (context, artists, _) {
              if (artists.isEmpty) {
                return const EmptyHint(text: 'Artists you listen to will show up here.');
              }
              return HList(
                height: 170,
                itemCount: artists.length,
                itemBuilder: (context, i) {
                  final a = artists[i];
                  return MediaTile(
                    title: a.name,
                    subtitle: a.plays == 1 ? '1 play' : '${a.plays} plays',
                    imageUrl: a.imageUrl,
                    circular: true,
                    size: 120,
                    fallbackIcon: Icons.person,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => ArtistScreen(name: a.name)),
                    ),
                  );
                },
              );
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }
}
