import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import '../services/feed_service.dart';
import '../services/artist_mix_service.dart';
import '../services/playlist_service.dart';
import '../widgets/layout.dart';
import '../widgets/media_tile.dart';
import '../widgets/recently_played.dart';
import '../widgets/track_carousel.dart';
import 'artist_mix_screen.dart';
import 'playlist_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = FeedService.instance;
    return RefreshIndicator(
      // The lists reload in the background (each section shows its own spinner).
      // Waiting for them here kept the pull-down spinner going for minutes.
      onRefresh: () async {
        unawaited(feed.refreshAll(force: true).catchError((Object e) {
          debugPrint('home refresh failed: $e');
        }));
        await Future<void>.delayed(const Duration(milliseconds: 700));
      },
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverToBoxAdapter(child: ScreenHeader(title: 'Home')),
          SectionSliver(
            title: 'Made for you',
            subtitle: 'A mix for each artist you listen to',
            trailing: _BusyDot(listenable: ArtistMixService.instance.loading),
            child: ValueListenableBuilder<List<ArtistMix>>(
              valueListenable: ArtistMixService.instance.mixes,
              builder: (_, mixes, _) {
                if (mixes.isEmpty) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: ArtistMixService.instance.loading,
                    builder: (_, loading, _) => EmptyHint(
                      text: 'Listen to a few songs by an artist and we\'ll make a mix for them.',
                      loading: loading,
                    ),
                  );
                }
                return HList(
                  height: 200,
                  itemCount: mixes.length,
                  itemBuilder: (context, i) {
                    final m = mixes[i];
                    return MediaTile(
                      title: m.title,
                      subtitle: '${m.tracks.length} songs',
                      imageUrl: m.imageUrl,
                      fallbackIcon: Icons.person,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ArtistMixScreen(artist: m.artist),
                        ),
                      ),
                    );
                  },
                );
              },
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
            trailing: _BusyDot(listenable: feed.loadingTrending),
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

/// Small spinner in a section header while that section is reloading.
class _BusyDot extends StatelessWidget {
  final ValueListenable<bool> listenable;
  const _BusyDot({required this.listenable});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (_, busy, _) => SizedBox(
        width: 16,
        height: 16,
        child: busy
            ? const CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)
            : null,
      ),
    );
  }
}
