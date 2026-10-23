import 'package:cached_network_image/cached_network_image.dart';
import 'download_widgets.dart';
import 'favourite_button.dart';
import 'playlist_sheets.dart';
import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:xtify_app/services/audio_service.dart';
import 'package:xtify_app/services/cookie_service.dart';
import 'package:xtify_app/screens/youtube_login_screen.dart';
import 'package:rxdart/rxdart.dart';

class PlayerSheet extends StatefulWidget {
  const PlayerSheet({super.key});

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> {
  // How far the sheet is pulled up (0.11 = collapsed); the download banner hides when it is open.
  final ValueNotifier<double> _extent = ValueNotifier<double>(0.11);

  @override
  void dispose() {
    _extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final collapsed = c.maxHeight.isFinite ? c.maxHeight * 0.11 : 90.0;
        return Stack(
          fit: StackFit.expand,
          children: [
            NotificationListener<DraggableScrollableNotification>(
              onNotification: (n) {
                _extent.value = n.extent;
                return false;
              },
              child: _sheet(context),
            ),
            // Download progress card, floating just above the collapsed mini player
            Positioned(
              left: 12,
              right: 12,
              bottom: collapsed + 8,
              child: ValueListenableBuilder<double>(
                valueListenable: _extent,
                builder: (_, e, child) => IgnorePointer(
                  ignoring: e > 0.2,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: e > 0.2 ? 0 : 1,
                    child: child,
                  ),
                ),
                child: const DownloadBanner(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _sheet(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: CookieService.instance.signedInListener,
      builder: (context, signedIn, child) {
        return DraggableScrollableSheet(
          initialChildSize: signedIn ? 0.11 : 0.11,
          minChildSize: signedIn ? 0.11 : 0.11,
          maxChildSize: signedIn ? 0.70 : 0.11,
          snap: signedIn,
          snapSizes: signedIn ? [0.11, 0.70] : null,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.zero,
                children: [
                  // 40x5 rounded drag handle, centered, vertical margin 10
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    child: Center(
                      child: Container(
                        width: 40,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(2.5),
                        ),
                      ),
                    ),
                  ),
                  // Divider
                  const Divider(),
                  // Header row visible when collapsed (bold 18)
                  _buildHeader(context, signedIn, scrollController),
                  // Expanded content: progress indicator, details, controls
                  if (signedIn) _buildExpandedContent(context, scrollController),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, bool signedIn, ScrollController scrollController) {
    if (!signedIn) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Sign in to YouTube to play music',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final ok = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute<bool>(
                    builder: (_) => const YoutubeLoginScreen(),
                  ),
                );
                if (ok == true) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Signed in to YouTube')),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      );
    }

    // Signed in: show current track or "Nothing playing"
    return StreamBuilder<List<dynamic>>(
      stream: Rx.combineLatest2<PlaybackState, MediaItem?, List<dynamic>>(
        XtifyAudioHandler.instance.playbackState,
        XtifyAudioHandler.instance.mediaItem,
        (PlaybackState playbackState, MediaItem? mediaItem) => [playbackState, mediaItem],
      ),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox.shrink();
        }
        final PlaybackState playbackState = snapshot.data![0] as PlaybackState;
        final MediaItem? mediaItem = snapshot.data![1] as MediaItem?;

        if (mediaItem == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Nothing playing',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Album art (grey music-note fallback)
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  image: mediaItem.artUri != null
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(mediaItem.artUri.toString()),
                          fit: BoxFit.cover,
                        )
                      : null,
                  color: Colors.grey,
                ),
                child: mediaItem.artUri == null
                    ? const Icon(
                        Icons.music_note,
                        size: 24,
                        color: Colors.white54,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      mediaItem.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      mediaItem.artist ?? 'Unknown Artist',
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  playbackState.playing
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                ),
                onPressed: () {
                  if (playbackState.playing) {
                    XtifyAudioHandler.instance.pause();
                  } else {
                    XtifyAudioHandler.instance.play();
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildExpandedContent(BuildContext context, ScrollController scrollController) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Large art
          StreamBuilder<MediaItem?>(
            stream: XtifyAudioHandler.instance.mediaItem,
            builder: (context, snapshot) {
              final mediaItem = snapshot.data;
              return Container(
                width: double.infinity,
                height: 200,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  image: mediaItem?.artUri != null
                      ? DecorationImage(
                          image: CachedNetworkImageProvider(mediaItem!.artUri.toString()),
                          fit: BoxFit.cover,
                        )
                      : null,
                  color: Colors.grey,
                ),
                child: mediaItem?.artUri == null
                    ? const Icon(
                        Icons.music_note,
                        size: 64,
                        color: Colors.white54,
                      )
                    : null,
              );
            },
          ),
          // Title and artist
          StreamBuilder<MediaItem?>(
            stream: XtifyAudioHandler.instance.mediaItem,
            builder: (context, snapshot) {
              final mediaItem = snapshot.data;
              if (mediaItem == null) {
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  Text(
                    mediaItem.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mediaItem.artist ?? 'Unknown Artist',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          // Progress bar
          StreamBuilder<Duration>(
            stream: AudioService.position,
            builder: (context, positionSnapshot) {
              final position = positionSnapshot.data ?? Duration.zero;
              return StreamBuilder<MediaItem?>(
                stream: XtifyAudioHandler.instance.mediaItem,
                builder: (context, mediaItemSnapshot) {
                  final mediaItem = mediaItemSnapshot.data;
                  final duration = mediaItem?.duration ?? Duration.zero;
                  final PlaybackState playbackState = XtifyAudioHandler.instance.playbackState.value;
                  return ProgressBar(
                    progress: position,
                    buffered: playbackState.bufferedPosition,
                    total: duration,
                    onSeek: (position) async {
                      await XtifyAudioHandler.instance.seek(position);
                    },
                    barHeight: 3.0,
                    baseBarColor: Colors.grey.withValues(alpha: 0.5),
                    progressBarColor: Colors.white,
                    thumbGlowColor: Colors.transparent,
                    thumbRadius: 6.0,
                  );
                },
              );
            },
          ),
          const SizedBox(height: 16),
          // Controls: previous / play-pause / next
          StreamBuilder<PlaybackState>(
            stream: XtifyAudioHandler.instance.playbackState,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SizedBox.shrink();
              }
              final PlaybackState playbackState = snapshot.data!;

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Builder(builder: (context) {
                    final t = XtifyAudioHandler.instance.currentTrack;
                    return t == null
                        ? const SizedBox(width: 48)
                        : FavouriteButton(track: t, size: 26);
                  }),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.skip_previous, size: 28),
                    onPressed: () {
                      XtifyAudioHandler.instance.skipToPrevious();
                    },
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(
                      playbackState.playing
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                      size: 28,
                    ),
                    onPressed: () {
                      if (playbackState.playing) {
                        XtifyAudioHandler.instance.pause();
                      } else {
                        XtifyAudioHandler.instance.play();
                      }
                    },
                    color: Colors.white,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 28),
                    onPressed: () {
                      XtifyAudioHandler.instance.skipToNext();
                    },
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.playlist_add, size: 26),
                    tooltip: 'Add to playlist',
                    onPressed: () {
                      final t = XtifyAudioHandler.instance.currentTrack;
                      if (t != null) showAddToPlaylistSheet(context, t);
                    },
                    color: Colors.white,
                  ),
                  Builder(builder: (context) {
                    final t = XtifyAudioHandler.instance.currentTrack;
                    return t == null
                        ? const SizedBox(width: 48)
                        : DownloadButton(track: t, size: 26);
                  }),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          // Up next
          const Text(
            'Up next',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          StreamBuilder<List<MediaItem>>(
            stream: XtifyAudioHandler.instance.queue,
            builder: (context, snapshot) {
              final queue = snapshot.data ?? [];
              final upcoming = queue.length > 1 ? queue.sublist(1) : <MediaItem>[];
              return ValueListenableBuilder<bool>(
                valueListenable: XtifyAudioHandler.instance.findingNext,
                builder: (context, finding, _) {
                  if (upcoming.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          if (finding) ...[
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white54,
                              ),
                            ),
                            const SizedBox(width: 12),
                          ],
                          Expanded(
                            child: Text(
                              finding
                                  ? 'Finding the next song…'
                                  : 'The next song is picked automatically',
                              style: const TextStyle(color: Colors.grey, fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (var i = 0; i < upcoming.length; i++)
                        ListTile(
                          onTap: () =>
                              XtifyAudioHandler.instance.skipToQueueItem(i + 1),
                          leading: upcoming[i].artUri != null
                              ? Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(4),
                                    image: DecorationImage(
                                      image: CachedNetworkImageProvider(
                                          upcoming[i].artUri.toString()),
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.music_note,
                                  size: 28, color: Colors.white54),
                          title: Text(
                            upcoming[i].title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                          ),
                          subtitle: Text(
                            upcoming[i].artist ?? 'Unknown Artist',
                            style: const TextStyle(color: Colors.grey, fontSize: 12),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}
