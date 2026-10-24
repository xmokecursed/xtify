import 'package:flutter/material.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import 'package:flutter/services.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';

/// Heart that adds/removes a song from the Favourites playlist.
class FavouriteButton extends StatelessWidget {
  final Track track;
  final double size;

  const FavouriteButton({super.key, required this.track, this.size = 22});

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    return ValueListenableBuilder<List<Playlist>>(
      valueListenable: PlaylistService.instance.playlists,
      builder: (context, _, _) {
        final fav = PlaylistService.instance.isFavourite(track.id);
        return IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: fav ? 'Remove from Favourites' : 'Add to Favourites',
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: Icon(
              fav ? Icons.favorite : Icons.favorite_border,
              key: ValueKey(fav),
              size: size,
              color: fav ? Colors.white : Colors.white70,
            ),
          ),
          color: Colors.white,
          onPressed: () async {
            HapticFeedback.selectionClick();
            final nowFav = await PlaylistService.instance.toggleFavourite(track);
            messenger.hideCurrentSnackBar();
            messenger.showSnackBar(SnackBar(
              duration: const Duration(seconds: 2),
              content: Text(nowFav ? 'Added to Favourites' : 'Removed from Favourites'),
            ));
          },
        );
      },
    );
  }
}
