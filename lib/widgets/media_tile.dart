import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';
import '../utils/image_cache.dart';
import 'pressable.dart';

/// Picture for a URL, or for a file:// URI (covers of downloaded songs work offline).
ImageProvider artProviderFor(String url) {
  if (url.startsWith('file://')) return FileImage(File.fromUri(Uri.parse(url)));
  return CachedNetworkImageProvider(url);
}

/// Square (or round) artwork with a gray fallback icon.
class ArtImage extends StatelessWidget {
  final String url;
  final double size;
  final double radius;
  final bool circular;
  final IconData fallbackIcon;

  const ArtImage({
    super.key,
    required this.url,
    required this.size,
    this.radius = 12,
    this.circular = false,
    this.fallbackIcon = Icons.music_note,
  });

  Widget _fallback() =>
      Center(child: Icon(fallbackIcon, color: Colors.white38, size: size * 0.35));

  ImageProvider? _localCover(String url) {
    final path = DownloadService.instance.coverFor(url);
    if (path == null) return null;
    return ResizeImage(FileImage(File(path)), width: (size * 3).round());
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: circular ? BorderRadius.circular(size / 2) : asymRadius(radius),
      child: Container(
        width: size,
        height: size,
        color: AppColors.card,
        child: url.isEmpty
            ? _fallback()
            : Image(
                // a downloaded song's cover comes from the phone: instant and offline
                image: _localCover(url) ??
                    CachedNetworkImageProvider(
                      url,
                      maxWidth: (size * 3).round(),
                      cacheManager: XtifyImageCache.instance,
                    ),
                width: size,
                height: size,
                fit: BoxFit.cover,
                // fade the cover in instead of popping
                frameBuilder: (_, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOut,
                        child: child,
                      ),
                errorBuilder: (_, _, _) => _fallback(),
              ),
      ),
    );
  }
}

/// Artwork with the title and subtitle underneath. Used in every carousel so
/// songs, playlists and artists all line up the same way.
class MediaTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final String imageUrl;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool circular;
  final IconData fallbackIcon;
  final Widget? badge;
  final double size;

  const MediaTile({
    super.key,
    required this.title,
    required this.imageUrl,
    this.subtitle,
    this.onTap,
    this.onLongPress,
    this.circular = false,
    this.fallbackIcon = Icons.music_note,
    this.badge,
    this.size = 140,
  });

  @override
  Widget build(BuildContext context) {
    final align = circular ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = circular ? TextAlign.center : TextAlign.start;
    return SizedBox(
      width: size,
      child: Pressable(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: align,
          children: [
            Stack(
              children: [
                ArtImage(
                  url: imageUrl,
                  size: size,
                  circular: circular,
                  fallbackIcon: fallbackIcon,
                ),
                if (badge != null) Positioned(right: 6, bottom: 6, child: badge!),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: size,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: textAlign,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: SizedBox(
                  width: size,
                  child: Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: textAlign,
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
