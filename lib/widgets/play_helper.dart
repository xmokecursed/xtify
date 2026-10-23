import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/audio_service.dart';
import 'loading_track_card.dart';

/// Plays [track] and keeps the user informed (preparing / error + retry).
Future<void> playTrackWithFeedback(BuildContext context, Track track) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      padding: EdgeInsets.zero,
      content: LoadingTrackCard(track: track),
      duration: const Duration(minutes: 2), // hidden as soon as playback starts or fails
    ),
  );

  try {
    await XtifyAudioHandler.instance.playTrack(track);
    messenger.hideCurrentSnackBar();
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Could not play "${track.title}"'),
        action: SnackBarAction(
          label: 'Retry',
          onPressed: () {
            if (context.mounted) playTrackWithFeedback(context, track);
          },
        ),
        duration: const Duration(seconds: 8),
      ),
    );
    debugPrint('play failed for ${track.id}: $e');
  }
}
