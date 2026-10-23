import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../theme/app_theme.dart';
import 'favourite_button.dart';
import 'media_tile.dart';
import 'play_helper.dart';
import 'playlist_sheets.dart';

/// Full-width song row: art, title/artist, duration, heart and a more menu.
class TrackRow extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;
  final bool showFavourite;
  final bool showMore;

  const TrackRow({
    super.key,
    required this.track,
    this.onTap,
    this.showFavourite = true,
    this.showMore = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap ?? () => playTrackWithFeedback(context, track),
      onLongPress: () => showTrackOptions(context, track),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screen, vertical: 8),
        child: Row(
          children: [
            ArtImage(url: track.imageUrl, size: 54, radius: 8),
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
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track.artist.isEmpty
                        ? track.duration
                        : '${track.artist} · ${track.duration}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            if (showFavourite) FavouriteButton(track: track),
            if (showMore)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'More',
                icon: const Icon(Icons.more_horiz, size: 22),
                onPressed: () => showTrackOptions(context, track),
              ),
          ],
        ),
      ),
    );
  }
}
