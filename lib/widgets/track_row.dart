import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../desktop/desktop_scope.dart';
import '../models/track_model.dart';
import '../theme/app_theme.dart';
import 'download_widgets.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';
import 'favourite_button.dart';
import 'media_tile.dart';
import 'play_helper.dart';
import 'playlist_sheets.dart';

class TrackRow extends StatelessWidget {
  final Track track;
  final VoidCallback? onTap;
  final bool showFavourite;
  final bool showDownload;
  final bool showMore;

  final String? searchedFor;

  const TrackRow({
    super.key,
    required this.track,
    this.onTap,
    this.showFavourite = true,
    this.showDownload = true,
    this.showMore = true,
    this.searchedFor,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [ConnectivityService.instance.online, DownloadService.instance.items]),
      builder: (context, _) => Opacity(
        opacity: playableNow(track) ? 1 : 0.4,
        child: _row(context),
      ),
    );
  }

  Widget _row(BuildContext context) {
    final wide = DesktopScope.isWide(context);
    final row = InkWell(
      hoverColor: wide ? AppColors.highlight : null,
      onTap: playableNow(track)
          ? (onTap ?? () => playTrackWithFeedback(context, track, searchedFor: searchedFor))
          : () => playTrackWithFeedback(context, track, searchedFor: searchedFor),
      onLongPress: () => showTrackOptions(context, track),
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: wide ? 12 : AppSpacing.screen, vertical: 8),
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
            if (showDownload) DownloadButton(track: track),
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
    if (!wide) return row;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen, vertical: 3),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.contextMenu): () =>
              showTrackOptions(context, track),
          const SingleActivator(LogicalKeyboardKey.f10, shift: true): () =>
              showTrackOptions(context, track),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTap: () => showTrackOptions(context, track),
          child: Material(
            color: AppColors.card,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: row,
          ),
        ),
      ),
    );
  }
}
