import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';
import 'download_widgets.dart';
import 'media_tile.dart';
import 'youtube_link.dart';
import '../screens/queue_screen.dart';
import '../models/track_model.dart';
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
                color: AppColors.surface,
                border: const Border(top: BorderSide(color: AppColors.border)),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    blurRadius: 28,
                    offset: const Offset(0, -6),
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
                    child: Align(
                      alignment: const Alignment(-0.82, 0),
                      child: Container(
                        width: 40,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2.5),
                        ),
                      ),
                    ),
                  ),
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
                  borderRadius: asymRadius(10),
                  image: mediaItem.artUri != null
                      ? DecorationImage(
                          image: artProviderFor(mediaItem.artUri.toString()),
                          fit: BoxFit.cover,
                        )
                      : null,
                  color: AppColors.card,
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
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      mediaItem.artist ?? 'Unknown Artist',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _PlayButton(playing: playbackState.playing, size: 42),
            ],
          ),
        );
      },
    );
  }

  Widget _buildExpandedContent(BuildContext context, ScrollController scrollController) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Large art: full-width square, centred
          StreamBuilder<MediaItem?>(
            stream: XtifyAudioHandler.instance.mediaItem,
            builder: (context, snapshot) {
              final mediaItem = snapshot.data;
              return Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 24),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    child: Container(
                      key: ValueKey(mediaItem?.artUri),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.6),
                            blurRadius: 32,
                            offset: const Offset(0, 14),
                          ),
                        ],
                        image: mediaItem?.artUri != null
                            ? DecorationImage(
                                image: artProviderFor(mediaItem!.artUri.toString()),
                                fit: BoxFit.cover,
                              )
                            : null,
                        color: AppColors.card,
                      ),
                      child: mediaItem?.artUri == null
                          ? const Icon(Icons.music_note, size: 64, color: Colors.white38)
                          : null,
                    ),
                  ),
                ),
              );
            },
          ),
          StreamBuilder<MediaItem?>(
            stream: XtifyAudioHandler.instance.mediaItem,
            builder: (context, snapshot) {
              final mediaItem = snapshot.data;
              if (mediaItem == null) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mediaItem.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mediaItem.artist ?? 'Unknown Artist',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 16,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
                    barHeight: 4.0,
                    baseBarColor: Colors.white12,
                    bufferedBarColor: Colors.white24,
                    progressBarColor: AppColors.accent,
                    thumbColor: Colors.white,
                    thumbGlowColor: Colors.transparent,
                    thumbRadius: 7.0,
                    timeLabelTextStyle: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 16),
          // Controls, centred: shuffle, previous, play/pause, next, repeat
          StreamBuilder<PlaybackState>(
            stream: XtifyAudioHandler.instance.playbackState,
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const SizedBox.shrink();
              }
              final PlaybackState playbackState = snapshot.data!;
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const _ShuffleButton(),
                  IconButton(
                    icon: const Icon(Icons.skip_previous_rounded, size: 42),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      XtifyAudioHandler.instance.skipToPrevious();
                    },
                    color: Colors.white,
                  ),
                  _PlayButton(playing: playbackState.playing, size: 72),
                  IconButton(
                    icon: const Icon(Icons.skip_next_rounded, size: 42),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      XtifyAudioHandler.instance.skipToNext();
                    },
                    color: Colors.white,
                  ),
                  const _RepeatButton(),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const _ActionRow(),
          const SizedBox(height: 16),
          // Up next
          const Text(
            'Up next',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
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
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14),
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
                                      image: artProviderFor(
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
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
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

/// Round white play/pause button; the icon swaps with a little pop.
class _PlayButton extends StatelessWidget {
  final bool playing;
  final double size;
  const _PlayButton({required this.playing, required this.size});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.9,
      onTap: () {
        HapticFeedback.lightImpact();
        if (playing) {
          XtifyAudioHandler.instance.pause();
        } else {
          XtifyAudioHandler.instance.play();
        }
      },
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            key: ValueKey(playing),
            color: Colors.black,
            size: size * 0.62,
          ),
        ),
      ),
    );
  }
}

/// Shuffle, repeat, queue and the original YouTube link, under the main controls.
class _ShuffleButton extends StatelessWidget {
  const _ShuffleButton();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: h.shuffleOn,
      builder: (_, shuffle, _) => IconButton(
        tooltip: shuffle ? 'Shuffle on' : 'Shuffle off',
        icon: Icon(Icons.shuffle_rounded, color: shuffle ? Colors.white : Colors.white38),
        onPressed: () => h.setShuffle(!shuffle),
      ),
    );
  }
}

class _RepeatButton extends StatelessWidget {
  const _RepeatButton();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return ValueListenableBuilder<XtifyRepeat>(
      valueListenable: h.repeat,
      builder: (_, mode, _) => IconButton(
        tooltip: switch (mode) {
          XtifyRepeat.off => 'Repeat off',
          XtifyRepeat.all => 'Repeat all',
          XtifyRepeat.one => 'Repeat this song',
        },
        icon: Icon(
          mode == XtifyRepeat.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
          color: mode == XtifyRepeat.off ? Colors.white38 : Colors.white,
        ),
        onPressed: h.cycleRepeat,
      ),
    );
  }
}

/// Heart, playlist, download, queue and YouTube link in one centred row.
class _ActionRow extends StatelessWidget {
  const _ActionRow();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    // rebuild whenever the song changes so the buttons point at the new track
    return StreamBuilder<MediaItem?>(
      stream: h.mediaItem,
      builder: (context, _) => _buttons(context, h, h.currentTrack),
    );
  }

  Widget _buttons(BuildContext context, XtifyAudioHandler h, Track? t) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        t == null
            ? const SizedBox(width: 40)
            : FavouriteButton(track: t, size: 24),
        IconButton(
          tooltip: 'Add to playlist',
          icon: const Icon(Icons.playlist_add, size: 24),
          color: Colors.white,
          onPressed: () {
            if (t != null) showAddToPlaylistSheet(context, t);
          },
        ),
        t == null
            ? const SizedBox(width: 40)
            : DownloadButton(track: t, size: 24),
        ValueListenableBuilder<List<Track>>(
          valueListenable: h.upNextQueue,
          builder: (_, queue, _) => IconButton(
            tooltip: 'Queue',
            icon: Badge(
              isLabelVisible: queue.isNotEmpty,
              label: Text('${queue.length}'),
              child: const Icon(Icons.queue_music, color: Colors.white),
            ),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const QueueScreen())),
          ),
        ),
        IconButton(
          tooltip: 'Open original on YouTube',
          icon: const Icon(Icons.open_in_new, size: 22),
          color: Colors.white,
          onPressed: () {
            if (t != null && t.isPlayable) showYoutubeLink(context, t);
          },
        ),
      ],
    );
  }
}