import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/track_model.dart';
import '../theme/app_theme.dart';

String youtubeUrl(Track t) => 'https://www.youtube.com/watch?v=${t.id}';

/// Shows the original YouTube link of a song, with Copy and Open buttons.
Future<void> showYoutubeLink(BuildContext context, Track track) {
  final messenger = ScaffoldMessenger.of(context);
  final url = youtubeUrl(track);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      title: const Text('Original on YouTube'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (track.artist.isNotEmpty)
            Text(track.artist,
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 12),
          SelectableText(url, style: const TextStyle(fontSize: 13, color: Colors.white70)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: url));
            if (dialogContext.mounted) Navigator.pop(dialogContext);
            messenger.showSnackBar(const SnackBar(content: Text('Link copied')));
          },
          child: const Text('Copy'),
        ),
        TextButton(
          onPressed: () async {
            var ok = false;
            try {
              ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            } catch (_) {}
            if (dialogContext.mounted) Navigator.pop(dialogContext);
            if (!ok) {
              messenger.showSnackBar(
                  const SnackBar(content: Text('Could not open the link. Copy it instead.')));
            }
          },
          child: const Text('Open'),
        ),
      ],
    ),
  );
}
