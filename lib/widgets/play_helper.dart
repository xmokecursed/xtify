import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/audio_service.dart';
import '../screens/youtube_login_screen.dart';
import '../services/connectivity_service.dart';
import '../services/cookie_service.dart';
import '../services/download_service.dart';
import 'loading_track_card.dart';

bool playableNow(Track t) =>
    ConnectivityService.instance.online.value || DownloadService.instance.isDownloaded(t.id);

final Set<String> _loadingIds = {};

Future<void> playTrackWithFeedback(BuildContext context, Track track,
    {String? searchedFor}) async {
  if (!_loadingIds.add(track.id)) return;
  try {
    await _playWithFeedback(context, track, searchedFor);
  } finally {
    _loadingIds.remove(track.id);
  }
}

Future<void> _playWithFeedback(BuildContext context, Track track, String? searchedFor) async {
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
      duration: const Duration(minutes: 2),
    ),
  );

  try {
    await XtifyAudioHandler.instance.playTrack(track, searchedFor: searchedFor);
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
                  if (context.mounted) {
                    playTrackWithFeedback(context, track, searchedFor: searchedFor);
                  }
                },
              ),
        duration: const Duration(seconds: 8),
      ),
    );
    debugPrint('play failed for ${track.id}: $e');
  }
}
