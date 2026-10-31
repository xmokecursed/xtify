import 'dart:math' as math;
import 'download_widgets.dart';
import 'media_tile.dart';
import 'pressable.dart';
import 'youtube_link.dart';
import '../screens/queue_screen.dart';
import '../models/track_model.dart';
import '../theme/app_theme.dart';
import 'favourite_button.dart';
import 'playlist_sheets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:xtify_app/services/audio_service.dart';
import 'package:xtify_app/services/cookie_service.dart';
import 'package:xtify_app/screens/youtube_login_screen.dart';
import 'package:rxdart/rxdart.dart';

const double _collapsedFraction = 0.11;
const double _expandedFraction = 0.70;
// _collapsedFraction as a percentage, to split the height by flex (see build)
const int _collapsedPercent = 11;

class PlayerSheet extends StatefulWidget {
  const PlayerSheet({super.key});

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> {
  // How far the sheet is pulled up; the download banner hides when it is open.
  final ValueNotifier<double> _extent = ValueNotifier<double>(_collapsedFraction);
  final DraggableScrollableController _ctl = DraggableScrollableController();

  // One position stream for both progress displays, made once. Asking
  // AudioService.position again on every rebuild can hand out a new stream each
  // time, which means re-subscribing (and restarting its timer) whenever the
  // sheet rebuilds.
  late final Stream<Duration> _position = AudioService.position;

  @override
  void dispose() {
    _extent.dispose();
    _ctl.dispose();
    super.dispose();
  }

  void _expand() {
    if (!_ctl.isAttached) return;
    _ctl.animateTo(
      _expandedFraction,
      duration: AppMotion.medium,
      curve: AppMotion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
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
        // Download progress card, floating just above the collapsed mini player.
        // The collapsed sheet is _collapsedFraction of the height, so splitting
        // the height in those proportions puts the card right on top of it.
        // (This used to measure the height with a LayoutBuilder. That made the
        // whole player rebuild during layout, and when anything inside such a
        // builder throws, everything under it stays broken.)
        Positioned.fill(
          child: Column(
            children: [
              Expanded(
                flex: 100 - _collapsedPercent,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
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
                ),
              ),
              const Spacer(flex: _collapsedPercent),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sheet(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: CookieService.instance.signedInListener,
      builder: (context, signedIn, child) {
        return DraggableScrollableSheet(
          controller: _ctl,
          initialChildSize: _collapsedFraction,
          minChildSize: _collapsedFraction,
          maxChildSize: signedIn ? _expandedFraction : _collapsedFraction,
          snap: signedIn,
          snapSizes: signedIn ? [_collapsedFraction, _expandedFraction] : null,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0C0C0C),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppRadius.sheet),
                ),
                border: const Border(
                  top: BorderSide(color: AppColors.hairline),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.6),
                    blurRadius: 24,
                    offset: const Offset(0, -6),
                  ),
                ],
              ),
              child: ListView(
                controller: scrollController,
                padding: EdgeInsets.zero,
                children: [
                  // drag handle
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 6),
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.22),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  // Mini player (always visible); tap to open
                  _buildHeader(context, signedIn),
                  // Expanded content
                  if (signedIn) _buildExpandedContent(context),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, bool signedIn) {
    if (!signedIn) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen, vertical: 8),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Sign in to YouTube to play music',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
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
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      );
    }

    // Signed in: current track or "Nothing playing".
    // Two plain StreamBuilders on the handler's own streams. This used to build
    // a fresh Rx.combineLatest2(...) inside build(): that stream can only be
    // listened to once, and the sheet's ListView re-creates a child from the
    // same widget when it was dropped, so the second listen threw "Stream has
    // already been listened to".
    final h = XtifyAudioHandler.instance;
    return StreamBuilder<MediaItem?>(
      stream: h.mediaItem,
      initialData: h.mediaItem.valueOrNull,
      builder: (context, itemSnap) {
        final mediaItem = itemSnap.data;
        if (mediaItem == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppSpacing.screen, vertical: 14),
            child: Text(
              'Nothing playing',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _expand,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 4, AppSpacing.screen, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    ArtImage(
                      url: mediaItem.artUri?.toString() ?? '',
                      size: 44,
                      radius: 10,
                    ),
                    const SizedBox(width: AppSpacing.gap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            mediaItem.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
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
                              fontSize: 12.5,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    StreamBuilder<PlaybackState>(
                      stream: h.playbackState,
                      initialData: h.playbackState.valueOrNull,
                      builder: (context, stateSnap) => _PlayPauseButton(
                        playing: stateSnap.data?.playing ?? false,
                        size: 40,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _MiniProgress(duration: mediaItem.duration, position: _position),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildExpandedContent(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 12, AppSpacing.screen, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Large art, always square and centered
          StreamBuilder<MediaItem?>(
            stream: XtifyAudioHandler.instance.mediaItem,
            builder: (context, snapshot) {
              final mediaItem = snapshot.data;
              final url = mediaItem?.artUri?.toString() ?? '';
              // As wide as the screen allows inside the side padding, up to
              // 300. Read from MediaQuery instead of a LayoutBuilder so this
              // is built with the rest of the sheet, not during layout.
              final side = math.max(
                  0.0,
                  math.min(MediaQuery.sizeOf(context).width - 2 * AppSpacing.screen,
                      300.0));
              return AnimatedSwitcher(
                duration: AppMotion.medium,
                switchInCurve: AppMotion.curve,
                child: Container(
                  key: ValueKey(url),
                  width: side,
                  height: side,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.card + 4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.7),
                        blurRadius: 30,
                        offset: const Offset(0, 14),
                      ),
                    ],
                  ),
                  child: ArtImage(
                    url: url,
                    size: side,
                    radius: AppRadius.card + 4,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
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
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    mediaItem.artist ?? 'Unknown Artist',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 15,
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
            stream: _position,
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
                    baseBarColor: Colors.white.withValues(alpha: 0.16),
                    bufferedBarColor: Colors.white.withValues(alpha: 0.12),
                    progressBarColor: Colors.white,
                    thumbColor: Colors.white,
                    thumbGlowColor: Colors.transparent,
                    thumbRadius: 6.0,
                    barCapShape: BarCapShape.round,
                    timeLabelLocation: TimeLabelLocation.below,
                    timeLabelTextStyle: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),
          // Main controls: shuffle / previous / play / next / repeat
          const _MainControls(),
          const SizedBox(height: 16),
          // Secondary actions: favourite / download / playlist / queue / YouTube
          const _ActionRow(),
          const SizedBox(height: 28),
          // Up next
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Up next',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
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
                              style: const TextStyle(
                                  color: AppColors.textSecondary, fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (var i = 0; i < upcoming.length; i++)
                        InkWell(
                          onTap: () =>
                              XtifyAudioHandler.instance.skipToQueueItem(i + 1),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                ArtImage(
                                  url: upcoming[i].artUri?.toString() ?? '',
                                  size: 48,
                                  radius: 8,
                                ),
                                const SizedBox(width: AppSpacing.gap),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        upcoming[i].title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        upcoming[i].artist ?? 'Unknown Artist',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.textSecondary,
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
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

/// Round white play/pause button with an animated icon swap.
class _PlayPauseButton extends StatelessWidget {
  final bool playing;
  final double size;
  const _PlayPauseButton({required this.playing, required this.size});

  @override
  Widget build(BuildContext context) {
    return Pressable(
      haptic: true,
      scale: 0.9,
      debounce: const Duration(milliseconds: 120),
      onTap: () {
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
          duration: AppMotion.fast,
          transitionBuilder: (child, anim) => ScaleTransition(
            scale: anim,
            child: FadeTransition(opacity: anim, child: child),
          ),
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

/// Thin progress line under the mini player.
class _MiniProgress extends StatelessWidget {
  final Duration? duration;
  final Stream<Duration> position;
  const _MiniProgress({required this.duration, required this.position});

  @override
  Widget build(BuildContext context) {
    final total = duration?.inMilliseconds ?? 0;
    return StreamBuilder<Duration>(
      stream: position,
      builder: (context, snap) {
        final pos = snap.data?.inMilliseconds ?? 0;
        final v = total <= 0 ? 0.0 : (pos / total).clamp(0.0, 1.0);
        return ClipRRect(
          borderRadius: BorderRadius.circular(1.5),
          child: LinearProgressIndicator(
            value: v,
            minHeight: 3,
            backgroundColor: Colors.white.withValues(alpha: 0.12),
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        );
      },
    );
  }
}

/// Shuffle, previous, play/pause, next and repeat: five evenly spaced slots.
class _MainControls extends StatelessWidget {
  const _MainControls();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    const off = AppColors.textTertiary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: h.shuffleOn,
          builder: (_, shuffle, _) => _ModeButton(
            icon: Icons.shuffle_rounded,
            active: shuffle,
            tooltip: shuffle ? 'Shuffle on' : 'Shuffle off',
            onTap: () => h.setShuffle(!shuffle),
          ),
        ),
        IconButton(
          iconSize: 34,
          icon: const Icon(Icons.skip_previous_rounded),
          color: Colors.white,
          onPressed: () {
            HapticFeedback.selectionClick();
            h.skipToPrevious();
          },
        ),
        StreamBuilder<PlaybackState>(
          stream: h.playbackState,
          builder: (context, snapshot) =>
              _PlayPauseButton(playing: snapshot.data?.playing ?? false, size: 68),
        ),
        IconButton(
          iconSize: 34,
          icon: const Icon(Icons.skip_next_rounded),
          color: Colors.white,
          onPressed: () {
            HapticFeedback.selectionClick();
            h.skipToNext();
          },
        ),
        ValueListenableBuilder<XtifyRepeat>(
          valueListenable: h.repeat,
          builder: (_, mode, _) => _ModeButton(
            icon: mode == XtifyRepeat.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            active: mode != XtifyRepeat.off,
            tooltip: switch (mode) {
              XtifyRepeat.off => 'Repeat off',
              XtifyRepeat.all => 'Repeat all',
              XtifyRepeat.one => 'Repeat this song',
            },
            onTap: h.cycleRepeat,
          ),
        ),
      ],
    );
  }
}

/// Toggle icon: bright with a dot underneath when on, dim when off.
class _ModeButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  const _ModeButton({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Pressable(
        haptic: true,
        debounce: const Duration(milliseconds: 150),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: AppMotion.fast,
                child: Icon(
                  icon,
                  key: ValueKey(icon),
                  size: 24,
                  color: active ? Colors.white : AppColors.textTertiary,
                ),
              ),
              const SizedBox(height: 4),
              AnimatedContainer(
                duration: AppMotion.fast,
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active ? Colors.white : Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Favourite, download, add to playlist, queue and the YouTube link.
class _ActionRow extends StatelessWidget {
  const _ActionRow();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return StreamBuilder<MediaItem?>(
      stream: h.mediaItem,
      builder: (context, _) {
        final t = h.currentTrack;
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.card.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              t == null
                  ? const SizedBox(width: 48, height: 48)
                  : FavouriteButton(track: t, size: 24),
              t == null
                  ? const SizedBox(width: 48, height: 48)
                  : DownloadButton(track: t, size: 24),
              IconButton(
                icon: const Icon(Icons.playlist_add_rounded, size: 26),
                tooltip: 'Add to playlist',
                onPressed: () {
                  if (t != null) showAddToPlaylistSheet(context, t);
                },
              ),
              ValueListenableBuilder<List<Track>>(
                valueListenable: h.upNextQueue,
                builder: (_, queue, _) => IconButton(
                  tooltip: 'Queue',
                  icon: Badge(
                    isLabelVisible: queue.isNotEmpty,
                    backgroundColor: Colors.white,
                    textColor: Colors.black,
                    label: Text('${queue.length}'),
                    child: const Icon(Icons.queue_music_rounded, size: 26),
                  ),
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const QueueScreen())),
                ),
              ),
              IconButton(
                tooltip: 'Open original on YouTube',
                icon: const Icon(Icons.open_in_new_rounded, size: 24),
                onPressed: () {
                  if (t != null && t.isPlayable) showYoutubeLink(context, t);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
