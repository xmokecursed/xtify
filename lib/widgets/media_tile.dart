import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../desktop/desktop_scope.dart';
import '../desktop/hover_builder.dart';
import '../services/download_service.dart';
import '../theme/app_theme.dart';
import '../utils/image_cache.dart';
import 'pressable.dart';

ImageProvider artProviderFor(String url) {
  if (url.startsWith('file://')) return FileImage(File.fromUri(Uri.parse(url)));
  return CachedNetworkImageProvider(url);
}

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
    this.radius = AppRadius.art,
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
      borderRadius: BorderRadius.circular(circular ? size / 2 : radius),
      child: Container(
        width: size,
        height: size,
        color: AppColors.card,
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(circular ? size / 2 : radius),
          border: Border.all(color: AppColors.hairline),
        ),
        child: url.isEmpty
            ? _fallback()
            : Image(
                image: url.startsWith('file://')
                    ? ResizeImage(
                        FileImage(File.fromUri(Uri.parse(url))),
                        width: (size * 3).round(),
                      )
                    : _localCover(url) ??
                        CachedNetworkImageProvider(
                          url,
                          maxWidth: (size * 3).round(),
                          cacheManager: XtifyImageCache.instance,
                        ),
                width: size,
                height: size,
                fit: BoxFit.cover,
                frameBuilder: (_, child, frame, sync) => sync
                    ? child
                    : AnimatedOpacity(
                        opacity: frame == null ? 0 : 1,
                        duration: AppMotion.medium,
                        curve: AppMotion.curve,
                        child: child,
                      ),
                errorBuilder: (_, _, _) => _fallback(),
              ),
      ),
    );
  }
}

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
  final VoidCallback? onPlay;

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
    this.onPlay,
  });

  Widget _wide() {
    final align = circular ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final textAlign = circular ? TextAlign.center : TextAlign.start;
    return SizedBox(
      width: size + 24,
      child: HoverBuilder(
        builder: (context, hovered) => Pressable(
          onTap: onTap,
          onLongPress: onLongPress,
          focusRadius: 14,
          hoverTint: true,
          scale: 0.98,
          child: Padding(
            padding: const EdgeInsets.all(12),
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
                    if (badge != null) Positioned(right: 6, top: 6, child: badge!),
                    if (onPlay != null)
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: IgnorePointer(
                          ignoring: !hovered,
                          child: AnimatedOpacity(
                            opacity: hovered ? 1 : 0,
                            duration: const Duration(milliseconds: 150),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: onPlay,
                              child: Container(
                                width: 44,
                                height: 44,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Color(0x66000000),
                                      blurRadius: 12,
                                      offset: Offset(0, 4),
                                    ),
                                  ],
                                ),
                                child: const Icon(
                                  Icons.play_arrow_rounded,
                                  color: Colors.black,
                                  size: 28,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
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
                      letterSpacing: -0.1,
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
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (DesktopScope.isWide(context)) return _wide();
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
                  letterSpacing: -0.1,
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
