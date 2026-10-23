import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/image_cache.dart';

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

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(circular ? size / 2 : radius),
      child: Container(
        width: size,
        height: size,
        color: AppColors.card,
        child: url.isEmpty
            ? _fallback()
            : Image(
                image: CachedNetworkImageProvider(
                  url,
                  maxWidth: (size * 3).round(),
                  cacheManager: XtifyImageCache.instance,
                ),
                width: size,
                height: size,
                fit: BoxFit.cover,
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
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
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
