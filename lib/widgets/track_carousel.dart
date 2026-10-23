import 'package:flutter/material.dart';
import '../models/track_model.dart';
import 'layout.dart';
import 'media_tile.dart';
import 'play_helper.dart';
import 'playlist_sheets.dart';

/// Horizontal row of song tiles with loading / empty states.
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
        return MediaTile(
          title: t.title,
          subtitle: t.artist,
          imageUrl: t.imageUrl,
          onTap: () => playTrackWithFeedback(context, t),
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
      },
    );
  }
}
