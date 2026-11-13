import 'package:audio_service/audio_service.dart';
import 'package:audio_video_progress_bar/audio_video_progress_bar.dart';
import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_widgets.dart';
import '../widgets/favourite_button.dart';
import '../widgets/media_tile.dart';
import '../widgets/player_sheet.dart';
import '../widgets/pressable.dart';
import 'app_nav.dart';

class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: Color(0xFF080808),
        border: Border(top: BorderSide(color: AppColors.hairline)),
      ),
      child: const Row(
        children: [
          Expanded(flex: 3, child: _NowPlayingInfo()),
          Expanded(flex: 4, child: _CenterControls()),
          Expanded(flex: 3, child: _RightControls()),
        ],
      ),
    );
  }
}

class _NowPlayingInfo extends StatelessWidget {
  const _NowPlayingInfo();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return StreamBuilder<MediaItem?>(
      stream: h.mediaItem,
      initialData: h.mediaItem.valueOrNull,
      builder: (context, snap) {
        final item = snap.data;
        if (item == null) {
          return const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Nothing playing',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        final track = h.currentTrack;
        return Row(
          children: [
            Tooltip(
              message: 'Now playing (N)',
              child: Pressable(
                focusRadius: 8,
                onTap: AppNav.instance.toggleNowPlaying,
                child: ArtImage(
                  url: item.artUri?.toString() ?? '',
                  size: 56,
                  radius: 8,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    item.artist ?? 'Unknown Artist',
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
            if (track != null) FavouriteButton(track: track, size: 22),
          ],
        );
      },
    );
  }
}

class _CenterControls extends StatelessWidget {
  const _CenterControls();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ValueListenableBuilder<bool>(
                  valueListenable: h.shuffleOn,
                  builder: (_, on, _) => _BarIcon(
                    icon: Icons.shuffle_rounded,
                    tooltip: on ? 'Shuffle on (Ctrl+S)' : 'Shuffle off (Ctrl+S)',
                    active: on,
                    onTap: () => h.setShuffle(!on),
                  ),
                ),
                const SizedBox(width: 6),
                _BarIcon(
                  icon: Icons.skip_previous_rounded,
                  size: 30,
                  color: Colors.white,
                  tooltip: 'Previous (Ctrl+←)',
                  onTap: h.skipToPrevious,
                ),
                const SizedBox(width: 8),
                StreamBuilder<PlaybackState>(
                  stream: h.playbackState,
                  initialData: h.playbackState.valueOrNull,
                  builder: (_, snap) => _PlayButton(playing: snap.data?.playing ?? false),
                ),
                const SizedBox(width: 8),
                _BarIcon(
                  icon: Icons.skip_next_rounded,
                  size: 30,
                  color: Colors.white,
                  tooltip: 'Next (Ctrl+→)',
                  onTap: h.skipToNext,
                ),
                const SizedBox(width: 6),
                ValueListenableBuilder<XtifyRepeat>(
                  valueListenable: h.repeat,
                  builder: (_, mode, _) => _BarIcon(
                    icon: mode == XtifyRepeat.one
                        ? Icons.repeat_one_rounded
                        : Icons.repeat_rounded,
                    tooltip: switch (mode) {
                      XtifyRepeat.off => 'Repeat off (Ctrl+R)',
                      XtifyRepeat.all => 'Repeat all (Ctrl+R)',
                      XtifyRepeat.one => 'Repeat this song (Ctrl+R)',
                    },
                    active: mode != XtifyRepeat.off,
                    onTap: h.cycleRepeat,
                  ),
                ),
              ],
            ),
            const _BarProgress(),
          ],
        ),
      ),
    );
  }
}

class _BarIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final double size;
  final Color? color;

  const _BarIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.size = 22,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      iconSize: size,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      color: color ?? (active ? Colors.white : AppColors.textSecondary),
      icon: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Icon(icon),
          if (active)
            const Positioned(
              bottom: -8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
                child: SizedBox(width: 4, height: 4),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final bool playing;

  const _PlayButton({required this.playing});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: playing ? 'Pause (Space)' : 'Play (Space)',
      child: Pressable(
        scale: 0.94,
        focusRadius: 22,
        debounce: const Duration(milliseconds: 120),
        onTap: XtifyAudioHandler.instance.togglePlayPause,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.black,
            size: 28,
          ),
        ),
      ),
    );
  }
}

class _BarProgress extends StatefulWidget {
  const _BarProgress();

  @override
  State<_BarProgress> createState() => _BarProgressState();
}

class _BarProgressState extends State<_BarProgress> {
  late final Stream<Duration> _position = AudioService.position;

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    return StreamBuilder<MediaItem?>(
      stream: h.mediaItem,
      initialData: h.mediaItem.valueOrNull,
      builder: (context, itemSnap) {
        final total = itemSnap.data?.duration ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: _position,
          builder: (context, posSnap) {
            return ProgressBar(
              progress: posSnap.data ?? Duration.zero,
              buffered: h.playbackState.value.bufferedPosition,
              total: total,
              onSeek: h.seek,
              barHeight: 4,
              baseBarColor: Colors.white.withValues(alpha: 0.16),
              bufferedBarColor: Colors.white.withValues(alpha: 0.12),
              progressBarColor: Colors.white,
              thumbColor: Colors.white,
              thumbGlowColor: Colors.transparent,
              thumbRadius: 5,
              barCapShape: BarCapShape.round,
              timeLabelLocation: TimeLabelLocation.sides,
              timeLabelTextStyle: const TextStyle(
                fontSize: 11.5,
                color: AppColors.textSecondary,
              ),
            );
          },
        );
      },
    );
  }
}

class _RightControls extends StatelessWidget {
  const _RightControls();

  @override
  Widget build(BuildContext context) {
    final h = XtifyAudioHandler.instance;
    final nav = AppNav.instance;
    return LayoutBuilder(
      builder: (context, c) {
        final sliderWidth = (c.maxWidth - 5 * 48).clamp(0.0, 110.0).toDouble();
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            StreamBuilder<MediaItem?>(
              stream: h.mediaItem,
              initialData: h.mediaItem.valueOrNull,
              builder: (_, _) {
                final track = h.currentTrack;
                if (track == null) return const SizedBox.shrink();
                return DownloadButton(track: track, size: 22);
              },
            ),
            ValueListenableBuilder<bool>(
              valueListenable: nav.nowPlayingOpen,
              builder: (_, open, _) => _BarIcon(
                icon: Icons.view_sidebar_rounded,
                tooltip: 'Now playing panel (N)',
                active: open,
                onTap: nav.toggleNowPlaying,
              ),
            ),
            ValueListenableBuilder<List<Track>>(
              valueListenable: h.upNextQueue,
              builder: (_, queue, _) => IconButton(
                tooltip: 'Queue (Q)',
                visualDensity: VisualDensity.compact,
                color: AppColors.textSecondary,
                icon: Badge(
                  isLabelVisible: queue.isNotEmpty,
                  backgroundColor: Colors.white,
                  textColor: Colors.black,
                  label: Text('${queue.length}'),
                  child: const Icon(Icons.queue_music_rounded, size: 22),
                ),
                onPressed: nav.toggleQueue,
              ),
            ),
            const AutoQueueGear(),
            ValueListenableBuilder<double>(
              valueListenable: h.volume,
              builder: (context, v, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _BarIcon(
                    icon: v == 0
                        ? Icons.volume_off_rounded
                        : v < 0.5
                            ? Icons.volume_down_rounded
                            : Icons.volume_up_rounded,
                    tooltip: v == 0 ? 'Unmute (M)' : 'Mute (M)',
                    onTap: h.toggleMute,
                  ),
                  if (sliderWidth >= 48)
                    SizedBox(
                      width: sliderWidth,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: const Color(0x33FFFFFF),
                          thumbColor: Colors.white,
                        ),
                        child: Slider(value: v, onChanged: h.setVolume),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
