import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import '../services/feed_service.dart';
import '../services/history_service.dart';
import '../services/playlist_service.dart';
import '../widgets/layout.dart';
import '../widgets/media_tile.dart';
import '../widgets/recently_played.dart';
import '../widgets/track_carousel.dart';
import 'playlist_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = FeedService.instance;
    return RefreshIndicator(
      onRefresh: () => feed.refreshAll(force: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: ScreenHeader(title: 'Home')),
          SectionSliver(
            title: 'Made for you',
            subtitle: 'Based on what you listen to',
            child: ValueListenableBuilder<bool>(
              valueListenable: feed.loadingMade,
              builder: (_, loading, _) => ValueListenableBuilder<List<Track>>(
                valueListenable: feed.madeForYou,
                builder: (_, tracks, _) => TrackCarousel(
                  tracks: tracks,
                  loading: loading,
                  emptyText: HistoryService.instance.tracks.value.isEmpty
                      ? "Play a few songs and we'll build this for you."
                      : 'Pull down to refresh.',
                ),
              ),
            ),
          ),
          const SectionSliver(title: 'Recently played', child: RecentlyPlayed()),
          SectionSliver(
            title: 'Your playlists',
            child: ValueListenableBuilder<List<Playlist>>(
              valueListenable: PlaylistService.instance.playlists,
              builder: (context, all, _) {
                // Favourites and Downloads only show up once they have a song in them
                final lists = all
                    .where((p) =>
                        (p.id != PlaylistService.favouritesId &&
                            p.id != PlaylistService.downloadsId) ||
                        p.tracks.isNotEmpty)
                    .toList();
                if (lists.isEmpty) {
                  return const EmptyHint(text: 'Create playlists from the Library tab.');
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
            title: 'Explore more',
            subtitle: 'Trending on Last.fm',
            child: ValueListenableBuilder<bool>(
              valueListenable: feed.loadingTrending,
              builder: (_, loading, _) => ValueListenableBuilder<List<Track>>(
                valueListenable: feed.trending,
                builder: (_, tracks, _) => TrackCarousel(
                  tracks: tracks,
                  loading: loading,
                  emptyText: 'Trending songs will show up here.',
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ],
      ),
    );
  }
}
