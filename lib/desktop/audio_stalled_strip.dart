import 'package:flutter/material.dart';
import '../services/audio_service.dart';
import '../theme/app_theme.dart';

class AudioStalledStrip extends StatelessWidget {
  const AudioStalledStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final handler = XtifyAudioHandler.instance;
    return ValueListenableBuilder<bool>(
      valueListenable: handler.stalled,
      builder: (context, stalled, _) => AnimatedSize(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        alignment: Alignment.bottomCenter,
        child: !stalled
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Material(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: handler.play,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.hairline),
                      ),
                      child: const Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Playback stopped. Check your sound output or connection',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: Colors.white70),
                            ),
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Retry',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
