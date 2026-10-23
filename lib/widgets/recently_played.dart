import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/history_service.dart';
import 'track_carousel.dart';

class RecentlyPlayed extends StatelessWidget {
  const RecentlyPlayed({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Track>>(
      valueListenable: HistoryService.instance.tracks,
      builder: (context, tracks, _) =>
          TrackCarousel(tracks: tracks, emptyText: 'Nothing played yet'),
    );
  }
}
