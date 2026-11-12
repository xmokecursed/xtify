import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';
import 'favourite_button.dart';
import 'layout.dart';
import 'media_tile.dart';
import 'play_helper.dart';
import 'playlist_sheets.dart';

class TrackCarousel extends StatelessWidget {
  final List<Track> tracks;
  final bool loading;
  final String emptyText;

  const TrackCarousel({
    super.key,
    required this.tracks,
    required this.emptyText,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return EmptyHint(text: emptyText, loading: loading);
    return HList(
      height: 200,
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final t = tracks[i];
        return ListenableBuilder(
          listenable: Listenable.merge(
              [ConnectivityService.instance.online, DownloadService.instance.items]),
          builder: (context, _) => Opacity(
            opacity: playableNow(t) ? 1 : 0.4,
            child: _tile(context, t),
          ),
        );
      },
    );
  }

  Widget _tile(BuildContext context, Track t) {
    return MediaTile(
      title: t.title,
      subtitle: t.artist,
      imageUrl: t.imageUrl,
      onTap: () => playTrackWithFeedback(context, t),
      onPlay: () => playTrackWithFeedback(context, t),
      onLongPress: () => showTrackOptions(context, t),
      badge: GestureDetector(
        onTap: () => showTrackOptions(context, t),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: const BoxDecoration(
            color: Colors.black54,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.more_horiz, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}

class TrackGrid extends StatelessWidget {
  final List<Track> tracks;
  final bool loading;
  final String emptyText;
  final int maxItems;

  const TrackGrid({
    super.key,
    required this.tracks,
    required this.emptyText,
    this.loading = false,
    this.maxItems = 12,
  });

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return EmptyHint(text: emptyText, loading: loading);
    final shown = tracks.length > maxItems ? tracks.sublist(0, maxItems) : tracks;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
      child: LayoutBuilder(
        builder: (context, c) {
          const gap = 12.0;
          final columns = (c.maxWidth / 360).floor().clamp(1, 4).toInt();
          final width = (c.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final t in shown)
                SizedBox(width: width, height: 64, child: _GridCard(track: t)),
            ],
          );
        },
      ),
    );
  }
}

class _GridCard extends StatelessWidget {
  final Track track;

  const _GridCard({required this.track});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [ConnectivityService.instance.online, DownloadService.instance.items]),
      builder: (context, _) => Opacity(
        opacity: playableNow(track) ? 1 : 0.4,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTap: () => showTrackOptions(context, track),
          child: Material(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              hoverColor: AppColors.highlight,
              onTap: () => playTrackWithFeedback(context, track),
              onLongPress: () => showTrackOptions(context, track),
              child: Row(
                children: [
                  ArtImage(url: track.imageUrl, size: 64, radius: 0),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FavouriteButton(track: track, size: 20),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
