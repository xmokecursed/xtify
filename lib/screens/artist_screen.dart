import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/api_service.dart';
import '../services/audio_service.dart';
import '../services/history_service.dart';
import '../services/track_lookup.dart';
import '../theme/app_theme.dart';
import '../widgets/layout.dart';
import '../widgets/player_sheet.dart';
import '../widgets/track_row.dart';

class ArtistScreen extends StatefulWidget {
  final String name;
  const ArtistScreen({super.key, required this.name});

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  late final Future<List<Track>> _top = ApiService.getArtistTopTracks(widget.name);

  Future<void> _playKnown(Track t) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await XtifyAudioHandler.instance.playTrack(t);
    } catch (e) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not play this song')),
      );
    }
  }

  Future<void> _playByName(Track t) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
      content: Text('Finding song…'),
      duration: Duration(seconds: 30),
    ));
    try {
      final found = await TrackLookup.find(widget.name, t.title);
      messenger.hideCurrentSnackBar();
      if (found == null) {
        messenger.showSnackBar(SnackBar(content: Text('Could not find "${t.title}"')));
        return;
      }
      await XtifyAudioHandler.instance.playTrack(found);
    } catch (e) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not play this song')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final played = HistoryService.instance.tracks.value
        .where((t) => t.artist.toLowerCase() == widget.name.toLowerCase())
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 140),
            children: [
              if (played.isNotEmpty) ...[
                const SectionHeader(title: 'Played by you'),
                for (final t in played)
                  TrackRow(track: t, onTap: () => _playKnown(t)),
              ],
              const SizedBox(height: AppSpacing.section),
              const SectionHeader(title: 'Popular'),
              FutureBuilder<List<Track>>(
                future: _top,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(32),
                      child: Center(child: CircularProgressIndicator(color: Colors.white54)),
                    );
                  }
                  final list = snap.data ?? const <Track>[];
                  if (snap.hasError || list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(AppSpacing.screen),
                      child: Text('No popular songs found.',
                          style: TextStyle(color: AppColors.textSecondary)),
                    );
                  }
                  return Column(
                    children: [
                      for (final t in list)
                        ListTile(
                          onTap: () => _playByName(t),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.screen),
                          leading: const Icon(Icons.music_note,
                              color: AppColors.textSecondary),
                          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
          const PlayerSheet(),
        ],
      ),
    );
  }
}
