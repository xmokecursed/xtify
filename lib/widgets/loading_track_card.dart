import 'dart:math';
import 'package:flutter/material.dart';
import '../models/track_model.dart';
import '../theme/app_theme.dart';
import 'media_tile.dart';

/// Shown while a song is being prepared: art, title, bouncing bars and a thin
/// progress line.
class LoadingTrackCard extends StatefulWidget {
  final Track track;
  const LoadingTrackCard({super.key, required this.track});

  @override
  State<LoadingTrackCard> createState() => _LoadingTrackCardState();
}

class _LoadingTrackCardState extends State<LoadingTrackCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
          child: Row(
            children: [
              ArtImage(url: widget.track.imageUrl, size: 44, radius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Loading',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    const SizedBox(height: 2),
                    Text(
                      widget.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AnimatedBuilder(
                animation: _c,
                builder: (_, _) => Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < 4; i++)
                      Container(
                        width: 4,
                        height: 6 + 16 * (0.5 + 0.5 * sin(2 * pi * (_c.value + i * 0.2))),
                        margin: const EdgeInsets.symmetric(horizontal: 1.5),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const LinearProgressIndicator(
          minHeight: 3,
          color: Colors.white,
          backgroundColor: AppColors.border,
        ),
      ],
    );
  }
}
