import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../screens/playlist_screen.dart';
import '../services/playlist_import_service.dart';
import '../services/playlist_service.dart';
import '../services/playlist_source.dart';
import '../theme/app_theme.dart';

class PlaylistImportSection extends StatefulWidget {
  const PlaylistImportSection({super.key});

  @override
  State<PlaylistImportSection> createState() => _PlaylistImportSectionState();
}

class _PlaylistImportSectionState extends State<PlaylistImportSection> {
  final TextEditingController _links = TextEditingController();
  String _message = '';

  @override
  void dispose() {
    _links.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    setState(() {
      _links.text = text;
      _message = '';
    });
  }

  void _clear() {
    setState(() {
      _links.clear();
      _message = '';
    });
  }

  void _start(List<PlaylistLink> found) {
    FocusScope.of(context).unfocus();
    final added = PlaylistImportService.instance.add(found);
    setState(() {
      if (added == 0) {
        _message = found.length == 1
            ? 'That playlist is already being imported.'
            : 'Those playlists are already being imported.';
        return;
      }
      _links.clear();
      _message = added < found.length ? 'Some of these are already being imported.' : '';
    });
  }

  Widget _status(List<PlaylistLink> found) {
    if (_message.isNotEmpty) {
      return _Hint(icon: Icons.info_outline_rounded, text: _message);
    }
    if (found.isNotEmpty) {
      final spotify = found.where((l) => l.source == PlaylistSource.spotify).length;
      final youtube = found.length - spotify;
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (spotify > 0) _SourceChip(name: 'Spotify', count: spotify),
          if (youtube > 0) _SourceChip(name: 'YouTube', count: youtube),
        ],
      );
    }
    if (_links.text.trim().isNotEmpty) {
      return const _Hint(
        icon: Icons.info_outline_rounded,
        text: 'No Spotify or YouTube playlist link found.',
      );
    }
    return const _Hint(
      icon: Icons.info_outline_rounded,
      text: 'Add as many links as you like, one per line.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = _links.text;
    final found = PlaylistLink.findAll(text);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(color: AppColors.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _links,
                  onChanged: (_) => setState(() => _message = ''),
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.surface,
                    hintText: 'Paste playlist links here',
                    hintStyle: const TextStyle(color: AppColors.textSecondary),
                    prefixIcon: const Icon(Icons.link_rounded,
                        size: 20, color: AppColors.textSecondary),
                    suffixIcon: text.isEmpty
                        ? IconButton(
                            tooltip: 'Paste',
                            icon: const Icon(Icons.content_paste_rounded,
                                size: 20, color: AppColors.textSecondary),
                            onPressed: _paste,
                          )
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.close_rounded,
                                size: 20, color: AppColors.textSecondary),
                            onPressed: _clear,
                          ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                AnimatedSize(
                  duration: AppMotion.fast,
                  curve: AppMotion.curve,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: double.infinity,
                    child: _status(found),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: found.isEmpty ? null : () => _start(found),
                    style: FilledButton.styleFrom(
                      disabledBackgroundColor: AppColors.highlight,
                      disabledForegroundColor: AppColors.textTertiary,
                    ),
                    icon: const Icon(Icons.playlist_add_rounded, size: 20),
                    label: Text(
                      found.length > 1 ? 'Import ${found.length} playlists' : 'Import playlist',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Spotify shares about the first 100 songs of a playlist. '
                  'Mixes and Liked songs cannot be imported.',
                  style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<List<ImportJob>>(
            valueListenable: PlaylistImportService.instance.jobs,
            builder: (context, jobs, _) {
              final active = jobs.where((j) => j.active).toList();
              final finished = jobs.where((j) => !j.active).toList()
                ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
              if (jobs.isEmpty) return const SizedBox(height: 4);
              return Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final j in active) _JobCard(key: ValueKey(j.id), job: j),
                    for (final j in finished) _JobCard(key: ValueKey(j.id), job: j),
                    if (finished.length > 1)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: PlaylistImportService.instance.clearFinished,
                          child: const Text('Clear reports'),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _Hint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, height: 1.3, color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _SourceChip extends StatelessWidget {
  final String name;
  final int count;

  const _SourceChip({required this.name, required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.highlight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_rounded, size: 16),
          const SizedBox(width: 6),
          Text(
            count == 1 ? '$name playlist' : '$count $name playlists',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _JobCard extends StatelessWidget {
  final ImportJob job;

  const _JobCard({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: AppColors.hairline),
        ),
        child: ListenableBuilder(
          listenable: job,
          builder: (context, _) => job.active ? _Running(job: job) : _Report(job: job),
        ),
      ),
    );
  }
}

String _titleOf(ImportJob job) =>
    job.title.isEmpty ? '${job.link.sourceName} playlist' : job.title;

class _Running extends StatelessWidget {
  final ImportJob job;

  const _Running({required this.job});

  String _status() {
    switch (job.phase) {
      case ImportPhase.queued:
        return 'Waiting for the earlier imports to finish';
      case ImportPhase.reading:
        return job.total == 0
            ? 'Reading the playlist…'
            : 'Reading the playlist · ${job.total} songs found';
      default:
        final missing = job.failed.isEmpty ? '' : ' · ${job.failed.length} not found';
        return 'Finding songs · ${job.processed} of ${job.total}$missing';
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = job.progress;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.highlight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.queue_music_rounded, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _titleOf(job),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${job.link.sourceName} playlist',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            if (progress != null)
              Text(
                '${(progress * 100).round()}%',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            IconButton(
              tooltip: job.stopRequested ? 'Stopping' : 'Stop',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed:
                  job.stopRequested ? null : () => PlaylistImportService.instance.stop(job),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LinearProgressIndicator(
          value: progress,
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
          backgroundColor: AppColors.border,
          color: Colors.white,
        ),
        const SizedBox(height: 10),
        Text(
          job.stopRequested ? 'Stopping…' : _status(),
          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _Report extends StatelessWidget {
  final ImportJob job;

  const _Report({required this.job});

  void _open(BuildContext context) {
    final id = job.playlistId;
    if (id == null) return;
    if (PlaylistService.instance.byId(id) == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('This playlist was deleted')));
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlaylistScreen(playlistId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final failedAll = job.phase == ImportPhase.failed;
    final failed = job.failed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              failedAll ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _titleOf(job),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: 'Remove report',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => PlaylistImportService.instance.remove(job),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (failedAll)
          Text(
            job.problem,
            style: const TextStyle(fontSize: 14, color: AppColors.textSecondary),
          )
        else ...[
          Text(
            '${job.imported} of ${job.total} songs imported',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Stat(label: 'Imported', value: job.imported),
              _Stat(label: 'Failed', value: failed.length),
              if (job.duplicates > 0) _Stat(label: 'Duplicates', value: job.duplicates),
              if (job.notTried > 0) _Stat(label: 'Not tried', value: job.notTried),
              if (job.hidden > 0) _Stat(label: 'Not shared', value: job.hidden),
            ],
          ),
          if (job.note.isNotEmpty) _Line(job.note),
          if (job.problem.isNotEmpty) _Line(job.problem),
          if (failed.isNotEmpty) _FailedList(failed: failed),
          if (job.playlistId != null) ...[
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => _open(context),
              icon: const Icon(Icons.queue_music_rounded, size: 20),
              label: const Text('Open playlist'),
            ),
          ],
        ],
      ],
    );
  }
}

class _Line extends StatelessWidget {
  final String text;

  const _Line(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, height: 1.35, color: AppColors.textSecondary),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final int value;

  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.highlight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$value', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _FailedList extends StatelessWidget {
  final List<FailedSong> failed;

  const _FailedList({required this.failed});

  static const int _shown = 300;

  @override
  Widget build(BuildContext context) {
    final count = failed.length > _shown ? _shown : failed.length;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: Colors.white,
        collapsedIconColor: AppColors.textSecondary,
        title: Text(
          'Songs that failed (${failed.length})',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: count + (failed.length > count ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == count) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'and ${failed.length - count} more',
                      style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                    ),
                  );
                }
                final f = failed[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(f.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                      Text(
                        f.reason,
                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
