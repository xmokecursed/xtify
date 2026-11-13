import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../desktop/app_nav.dart';
import '../desktop/desktop_scope.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import '../services/audio_service.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';
import '../services/feed_service.dart';
import '../services/artist_mix_service.dart';
import '../services/history_service.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import '../widgets/layout.dart';
import '../widgets/media_tile.dart';
import '../widgets/offline_banner.dart';
import '../widgets/play_helper.dart';
import '../widgets/recently_played.dart';
import '../widgets/track_carousel.dart';
import 'artist_mix_screen.dart';
import 'playlist_screen.dart';

String _greeting() {
  final hour = DateTime.now().hour;
  if (hour < 5) return 'Good night';
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
}

void _playAll(BuildContext context, List<Track> tracks) {
  if (tracks.isEmpty) return;
  XtifyAudioHandler.instance.playPlaylist(tracks).catchError((Object e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start playback')),
      );
    }
  });
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final feed = FeedService.instance;
    final wide = DesktopScope.isWide(context);
    return RefreshIndicator(
      onRefresh: () async {
        unawaited(feed.refreshAll(force: true).catchError((Object e) {
          debugPrint('home refresh failed: $e');
        }));
        await Future<void>.delayed(const Duration(milliseconds: 700));
      },
      child: ValueListenableBuilder<bool>(
        valueListenable: ConnectivityService.instance.online,
        builder: (context, online, _) => CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: wide
                ? ScreenHeader(title: _greeting())
                : const ScreenHeader(title: 'Xtify', showLogo: true),
          ),
          const SliverToBoxAdapter(child: OfflineBanner()),
          if (wide) const SliverToBoxAdapter(child: _Hero()),
          if (!online)
            SectionSliver(
              title: 'Downloaded songs',
              child: ValueListenableBuilder<Map<String, DownloadedItem>>(
                valueListenable: DownloadService.instance.items,
                builder: (_, items, _) => TrackCarousel(
                  tracks: (items.values.toList()..sort((a, b) => b.atMs.compareTo(a.atMs)))
                      .map((e) => e.track)
                      .toList(),
                  emptyText: 'Nothing downloaded yet.',
                ),
              ),
            ),
          if (online)
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
                      onPlay: () => _playAll(context, m.tracks),
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
                      onPlay: () => _playAll(context, p.tracks),
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
          if (online)
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
      ),
    );
  }
}

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

class _Hero extends StatefulWidget {
  const _Hero();

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> {
  final XtifyAudioHandler _handler = XtifyAudioHandler.instance;
  late final Stream<bool> _playing =
      _handler.playbackState.map((s) => s.playing).distinct();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: _playing,
      initialData: _handler.playbackState.valueOrNull?.playing ?? false,
      builder: (context, playingSnap) => StreamBuilder(
        stream: _handler.mediaItem,
        initialData: _handler.mediaItem.valueOrNull,
        builder: (context, _) => ListenableBuilder(
          listenable: Listenable.merge([
            HistoryService.instance.tracks,
            ArtistMixService.instance.mixes,
          ]),
          builder: (context, _) => AnimatedSize(
            duration: AppMotion.medium,
            curve: AppMotion.curve,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: AppMotion.fast,
              child: _card(context, playingSnap.data ?? false),
            ),
          ),
        ),
      ),
    );
  }

  ArtistMix? _mixFor(Track track) {
    final artist = track.artist.toLowerCase();
    for (final mix in ArtistMixService.instance.mixes.value) {
      final name = mix.artist.toLowerCase();
      if (name.isNotEmpty && mix.tracks.isNotEmpty && artist.contains(name)) {
        return mix;
      }
    }
    return null;
  }

  Widget _card(BuildContext context, bool playing) {
    final current = _handler.currentTrack;
    if (playing && current != null) {
      final mix = _mixFor(current);
      if (mix == null) {
        return const SizedBox.shrink(key: ValueKey('hero-hidden'));
      }
      return _HeroCard(
        key: ValueKey('hero-mix-${mix.artist}'),
        eyebrow: 'KEEP IT GOING',
        title: mix.title,
        subtitle: '${mix.tracks.length} songs picked from what you play',
        imageUrl: mix.imageUrl,
        actions: [
          FilledButton.icon(
            style: _heroFilled,
            onPressed: () => _playAll(context, mix.tracks),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Play mix'),
          ),
          OutlinedButton(
            style: _heroOutlined,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ArtistMixScreen(artist: mix.artist),
              ),
            ),
            child: const Text('Open'),
          ),
        ],
      );
    }
    final history = HistoryService.instance.tracks.value;
    final track = current ?? (history.isEmpty ? null : history.first);
    if (track == null) {
      return _HeroCard(
        key: const ValueKey('hero-welcome'),
        eyebrow: 'WELCOME',
        title: 'Find something to play',
        subtitle: 'Press Ctrl+K to search for songs and artists',
        imageUrl: null,
        actions: [
          FilledButton.icon(
            style: _heroFilled,
            onPressed: AppNav.instance.focusSearch,
            icon: const Icon(Icons.search_rounded),
            label: const Text('Search'),
          ),
        ],
      );
    }
    return _HeroCard(
      key: ValueKey('hero-resume-${track.id}'),
      eyebrow: 'JUMP BACK IN',
      title: track.title,
      subtitle: track.artist,
      imageUrl: track.imageUrl,
      actions: [
        FilledButton.icon(
          style: _heroFilled,
          onPressed: () => current != null
              ? _handler.play()
              : playTrackWithFeedback(context, track),
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Play'),
        ),
      ],
    );
  }
}

final ButtonStyle _heroFilled = FilledButton.styleFrom(
  backgroundColor: Colors.white,
  foregroundColor: Colors.black,
  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
  shape: const StadiumBorder(),
);

final ButtonStyle _heroOutlined = OutlinedButton.styleFrom(
  foregroundColor: Colors.white,
  side: const BorderSide(color: Color(0x44FFFFFF)),
  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
  shape: const StadiumBorder(),
);

class _HeroCard extends StatelessWidget {
  final String eyebrow;
  final String title;
  final String subtitle;
  final String? imageUrl;
  final List<Widget> actions;

  const _HeroCard({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final art = imageUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screen,
        0,
        AppSpacing.screen,
        AppSpacing.section,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 210),
        padding: const EdgeInsets.fromLTRB(32, 24, 24, 24),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.hairline),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2C2C30), Color(0xFF151517)],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eyebrow,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                      height: 1.05,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(spacing: 10, runSpacing: 10, children: actions),
                ],
              ),
            ),
            if (art != null) ...[
              const SizedBox(width: 24),
              ArtImage(url: art, size: 162, radius: 14),
            ],
          ],
        ),
      ),
    );
  }
}
