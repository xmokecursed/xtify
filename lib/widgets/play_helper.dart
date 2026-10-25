import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/audio_service.dart';
import '../screens/youtube_login_screen.dart';
import '../services/connectivity_service.dart';
import '../services/cookie_service.dart';
import '../services/download_service.dart';
import 'loading_track_card.dart';

/// False when the phone is offline and the song is not downloaded.
bool playableNow(Track t) =>
    ConnectivityService.instance.online.value || DownloadService.instance.isDownloaded(t.id);

/// Plays [track] and keeps the user informed (preparing / error + retry).
final Set<String> _loadingIds = {};

Future<void> playTrackWithFeedback(BuildContext context, Track track) async {
  // the same song is already loading: extra taps do nothing
  if (!_loadingIds.add(track.id)) return;
  try {
    await _playWithFeedback(context, track);
  } finally {
    _loadingIds.remove(track.id);
  }
}

Future<void> _playWithFeedback(BuildContext context, Track track) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  if (!playableNow(track)) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Offline: download this song to play it without internet')),
    );
    return;
  }
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
        action: CookieService.instance.needsSignInListener.value
            ? SnackBarAction(
                label: 'Sign in again',
                onPressed: () {
                  if (context.mounted) {
                    Navigator.of(context).push(MaterialPageRoute<bool>(
                        builder: (_) => const YoutubeLoginScreen()));
                  }
                },
              )
            : SnackBarAction(
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
