import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../screens/playlist_screen.dart';
import '../services/download_service.dart';
import '../services/playlist_service.dart';
import '../theme/app_theme.dart';
import 'media_tile.dart';

/// Download icon for one song. It animates between: download -> progress ring
/// (with a stop square, tap to cancel) -> green check.
class DownloadButton extends StatelessWidget {
  final Track track;
  final double size;

  const DownloadButton({super.key, required this.track, this.size = 22});

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    final messenger = ScaffoldMessenger.of(context);

    void say(String text, {SnackBarAction? action}) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 3),
        content: Text(text),
        action: action,
      ));
    }

    return ListenableBuilder(
      listenable: Listenable.merge([svc.items, svc.tasks]),
      builder: (context, _) {
        final Widget icon;
        final String tip;
        final VoidCallback onTap;
        final task = svc.tasks.value[track.id];
        if (svc.isDownloaded(track.id)) {
          icon = Icon(Icons.download_done,
              key: const ValueKey('done'), size: size, color: Colors.greenAccent);
          tip = 'Downloaded';
          onTap = () => say(
                'Saved on this phone',
                action: SnackBarAction(
                  label: 'Remove',
                  onPressed: () => svc.remove(track.id),
                ),
              );
        } else if (task != null && task.status != DownloadStatus.failed) {
          icon = _ProgressRing(
              key: const ValueKey('busy'), size: size, progress: _progressOf(task));
          tip = 'Cancel download';
          onTap = () => svc.cancel(track.id);
        } else if (task != null) {
          icon = Icon(Icons.error_outline,
              key: const ValueKey('failed'), size: size, color: Colors.orangeAccent);
          tip = 'Download failed, tap to retry';
          onTap = () {
            svc.enqueue(track);
            say('Retrying "${track.title}"');
          };
        } else {
          icon = Icon(Icons.download_outlined,
              key: const ValueKey('idle'), size: size, color: Colors.white);
          tip = 'Download';
          onTap = () {
            svc.enqueue(track);
            say('Downloading "${track.title}"');
          };
        }
        return IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: tip,
          onPressed: onTap,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.elasticOut,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, anim) => ScaleTransition(
              scale: anim,
              child: FadeTransition(opacity: anim.drive(CurveTween(curve: Curves.easeOut)), child: child),
            ),
            child: icon,
          ),
        );
      },
    );
  }
}

/// null = not started yet (spins), otherwise 0..1.
double? _progressOf(DownloadTask t) =>
    (t.status == DownloadStatus.active && t.progress > 0) ? t.progress : null;

/// Circular progress that glides between values, with a stop square inside.
class _ProgressRing extends StatelessWidget {
  final double size;
  final double? progress;
  const _ProgressRing({super.key, required this.size, required this.progress});

  @override
  Widget build(BuildContext context) {
    final box = size + 2;
    final value = progress; // a local, so the null check below promotes it
    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (value == null)
            const SizedBox.expand(
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            )
          else
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: value),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut,
              builder: (_, v, _) => SizedBox.expand(
                child: CircularProgressIndicator(
                  value: v,
                  strokeWidth: 2.4,
                  color: Colors.greenAccent,
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
          Icon(Icons.stop_rounded, size: size * 0.45, color: Colors.white70),
        ],
      ),
    );
  }
}

/// Bar that glides to its value; sweeps back and forth while the size is unknown.
class _SmoothBar extends StatelessWidget {
  final double? progress;
  const _SmoothBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    final value = progress; // a local, so the null check below promotes it
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: value == null
            ? const LinearProgressIndicator(
                minHeight: 5,
                color: Colors.greenAccent,
                backgroundColor: Colors.white12,
              )
            : TweenAnimationBuilder<double>(
                tween: Tween<double>(end: value),
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOut,
                builder: (_, v, _) => Stack(
                  children: [
                    const Positioned.fill(child: ColoredBox(color: Colors.white12)),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: v.clamp(0.02, 1.0),
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF1DE9B6), Color(0xFF69F0AE)],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

void _openDownloads(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => const PlaylistScreen(playlistId: PlaylistService.downloadsId),
  ));
}

/// Floating card that shows what is downloading, then "Saved" or "Failed".
/// It lives just above the mini player, so it is on every screen.
class DownloadBanner extends StatefulWidget {
  const DownloadBanner({super.key});

  @override
  State<DownloadBanner> createState() => _DownloadBannerState();
}

class _DownloadBannerState extends State<DownloadBanner> {
  DownloadEvent? _event;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    DownloadService.instance.lastEvent.addListener(_onEvent);
  }

  @override
  void dispose() {
    DownloadService.instance.lastEvent.removeListener(_onEvent);
    _timer?.cancel();
    super.dispose();
  }

  void _onEvent() {
    final e = DownloadService.instance.lastEvent.value;
    if (e == null || !mounted) return;
    setState(() => _event = e);
    _timer?.cancel();
    _timer = Timer(Duration(seconds: e.ok ? 3 : 7), () {
      if (mounted) setState(() => _event = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    return ValueListenableBuilder<Map<String, DownloadTask>>(
      valueListenable: svc.tasks,
      builder: (context, tasks, _) {
        final running =
            tasks.values.where((t) => t.status != DownloadStatus.failed).toList();
        Widget content;
        if (running.isNotEmpty) {
          final current = running.firstWhere(
            (t) => t.status == DownloadStatus.active,
            orElse: () => running.first,
          );
          content = _ActiveCard(
            key: const ValueKey('active'),
            task: current,
            total: running.length,
          );
        } else if (_event != null) {
          content = _ResultCard(key: ValueKey('result-${_event!.seq}'), event: _event!);
        } else {
          content = const SizedBox.shrink(key: ValueKey('none'));
        }
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero)
                  .animate(anim),
              child: child,
            ),
          ),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.bottomCenter,
            children: [...previous, if (current != null) current],
          ),
          child: content,
        );
      },
    );
  }
}

BoxDecoration _cardDecoration() => BoxDecoration(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppColors.border),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 14,
          offset: const Offset(0, 4),
        ),
      ],
    );

class _ActiveCard extends StatelessWidget {
  final DownloadTask task;
  final int total;
  const _ActiveCard({super.key, required this.task, required this.total});

  @override
  Widget build(BuildContext context) {
    final p = _progressOf(task);
    final finishing = p != null && p >= 0.995; // saving tags and cover
    final label = finishing
        ? 'Finishing…'
        : total > 1
            ? 'Downloading · $total songs'
            : 'Downloading';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDownloads(context),
        child: Container(
          decoration: _cardDecoration(),
          padding: const EdgeInsets.fromLTRB(10, 10, 4, 10),
          child: Row(
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  ArtImage(url: task.track.imageUrl, size: 44, radius: 10),
                  if (p != null)
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: p),
                      duration: const Duration(milliseconds: 300),
                      builder: (_, v, _) => Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${(v * 100).round()}%',
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.4,
                            color: Colors.greenAccent)),
                    const SizedBox(height: 2),
                    Text(
                      task.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                    const SizedBox(height: 7),
                    _SmoothBar(progress: p),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Cancel',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 20, color: Colors.white70),
                onPressed: () => DownloadService.instance.cancel(task.track.id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final DownloadEvent event;
  const _ResultCard({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final ok = event.ok;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: ok ? () => _openDownloads(context) : null,
        child: Container(
          decoration: _cardDecoration(),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
          child: Row(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: const Duration(milliseconds: 600),
                curve: Curves.elasticOut,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: (ok ? Colors.greenAccent : Colors.orangeAccent)
                        .withValues(alpha: 0.18),
                  ),
                  child: Icon(
                    ok ? Icons.check_rounded : Icons.priority_high_rounded,
                    color: ok ? Colors.greenAccent : Colors.orangeAccent,
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(ok ? 'Saved to Downloads' : 'Download failed',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 0.4,
                            color: ok ? Colors.greenAccent : Colors.orangeAccent)),
                    const SizedBox(height: 2),
                    Text(
                      event.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ],
                ),
              ),
              if (!ok)
                TextButton(
                  onPressed: () => DownloadService.instance.enqueue(event.track),
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The waiting / running / failed downloads, shown on top of the Downloads screen.
class DownloadQueueSection extends StatelessWidget {
  const DownloadQueueSection({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, DownloadTask>>(
      valueListenable: DownloadService.instance.tasks,
      builder: (context, tasks, _) {
        final list = tasks.values.toList();
        return AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: list.isEmpty
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(
                          AppSpacing.screen, 8, AppSpacing.screen, 4),
                      child: Text('In progress',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary)),
                    ),
                    for (final t in list) _QueueRow(task: t),
                    const Divider(height: 16),
                  ],
                ),
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  final DownloadTask task;
  const _QueueRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final failed = task.status == DownloadStatus.failed;
    final p = _progressOf(task);
    final status = failed
        ? 'Failed · tap to retry'
        : task.status == DownloadStatus.queued
            ? 'Waiting…'
            : p == null
                ? 'Starting…'
                : p >= 0.995
                    ? 'Finishing…'
                    : '${(p * 100).round()}%';
    return InkWell(
      onTap: failed ? () => DownloadService.instance.enqueue(task.track) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screen, vertical: 6),
        child: Row(
          children: [
            ArtImage(url: task.track.imageUrl, size: 46, radius: 8),
            const SizedBox(width: AppSpacing.gap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(task.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                  const SizedBox(height: 2),
                  Text(
                    task.track.artist.isEmpty
                        ? status
                        : '${task.track.artist} · $status',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: failed ? Colors.orangeAccent : AppColors.textSecondary),
                  ),
                  if (!failed) ...[
                    const SizedBox(height: 6),
                    _SmoothBar(progress: task.status == DownloadStatus.queued ? 0.0 : p),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: failed ? 'Dismiss' : 'Cancel',
              visualDensity: VisualDensity.compact,
              icon: Icon(failed ? Icons.close : Icons.stop_circle_outlined, size: 22),
              onPressed: () => DownloadService.instance.cancel(task.track.id),
            ),
          ],
        ),
      ),
    );
  }
}

/// Row showing where downloads are saved; tap to change it.
class DownloadFolderTile extends StatelessWidget {
  const DownloadFolderTile({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = DownloadService.instance;
    return ValueListenableBuilder<String>(
      valueListenable: svc.folder,
      builder: (context, path, _) => ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
        leading: const Icon(Icons.folder_outlined),
        title: ValueListenableBuilder<bool>(
          valueListenable: svc.customFolder,
          builder: (_, custom, _) => Text(
            custom ? 'Download folder' : 'Download folder (app storage)',
            style: const TextStyle(fontSize: 14),
          ),
        ),
        subtitle: Text(
          path,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showDownloadFolderSheet(context),
      ),
    );
  }
}

/// Lets the user pick a download folder or go back to the app's own one.
Future<void> showDownloadFolderSheet(BuildContext context) {
  final messenger = ScaffoldMessenger.of(context);
  final svc = DownloadService.instance;

  Future<void> choose(BuildContext sheetContext) async {
    Navigator.pop(sheetContext);
    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath();
    } catch (e) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not open the folder picker')));
      return;
    }
    if (picked == null) return; // cancelled
    final err = await svc.setFolder(picked);
    messenger.showSnackBar(SnackBar(
      content: Text(err ?? 'New downloads will be saved to $picked'),
    ));
  }

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.screen, 20, AppSpacing.screen, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Download folder',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.screen, 0, AppSpacing.screen, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ValueListenableBuilder<String>(
                valueListenable: svc.folder,
                builder: (_, p, _) => Text(
                  'Now: $p\nSongs you already downloaded stay where they are.',
                  style: const TextStyle(
                      fontSize: 13, color: AppColors.textSecondary),
                ),
              ),
            ),
          ),
          ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
            leading: const Icon(Icons.folder_open),
            title: const Text('Choose a folder'),
            onTap: () => choose(sheetContext),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: svc.customFolder,
            builder: (_, custom, _) => custom
                ? ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                    leading: const Icon(Icons.restore),
                    title: const Text('Use the default (app storage)'),
                    onTap: () async {
                      Navigator.pop(sheetContext);
                      await svc.setFolder(null);
                      messenger.showSnackBar(const SnackBar(
                          content: Text('New downloads will be saved in app storage')));
                    },
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
