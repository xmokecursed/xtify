import 'package:flutter/material.dart';
import '../services/artist_mix_service.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import '../widgets/player_sheet.dart';
import '../widgets/track_row.dart';

class ArtistMixScreen extends StatelessWidget {
  final String artist;
  const ArtistMixScreen({super.key, required this.artist});

  void _play(BuildContext context, ArtistMix m, {int start = 0, bool shuffle = false}) {
    XtifyAudioHandler.instance
        .playPlaylist(m.tracks, startIndex: start, shuffle: shuffle)
        .catchError((Object e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start playback')),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ArtistMix>>(
      valueListenable: ArtistMixService.instance.mixes,
      builder: (context, all, _) {
        final m = all
            .where((x) => x.artist.toLowerCase() == artist.toLowerCase())
            .firstOrNull;
        return Scaffold(
          appBar: AppBar(title: Text(m?.title ?? '$artist Mix')),
          body: Stack(
            children: [
              m == null || m.tracks.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(32),
                        child: Text(
                          'This mix is not ready yet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                              AppSpacing.screen, 8, AppSpacing.screen, 12),
                          child: Row(
                            children: [
                              FilledButton.icon(
                                onPressed: () => _play(context, m),
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Play'),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
                                onPressed: () => _play(context, m, shuffle: true),
                                icon: const Icon(Icons.shuffle),
                                label: const Text('Shuffle'),
                              ),
                              const Spacer(),
                              Text('${m.tracks.length} songs',
                                  style: const TextStyle(
                                      fontSize: 13, color: AppColors.textSecondary)),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            padding: const EdgeInsets.only(bottom: 140),
                            itemCount: m.tracks.length,
                            itemBuilder: (context, i) => TrackRow(
                              track: m.tracks[i],
                              onTap: () => _play(context, m, start: i),
                              showMore: false,
                            ),
                          ),
                        ),
                      ],
                    ),
              const PlayerSheet(),
            ],
          ),
        );
      },
    );
  }
}
