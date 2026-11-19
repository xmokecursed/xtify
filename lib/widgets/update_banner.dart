import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/update_service.dart' show UpdateInfo, UpdateService;
import '../theme/app_theme.dart';

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  static String _label(String url) =>
      Uri.tryParse(url)?.host == 'github.com' ? 'Github' : 'Download';

  Future<void> _open(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not open the download page.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateInfo?>(
      valueListenable: UpdateService.instance.available,
      builder: (context, info, _) => AnimatedSize(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        alignment: Alignment.topCenter,
        child: info == null
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screen, 8, AppSpacing.screen, 8),
                child: Material(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _open(context, info.url),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.hairline),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, size: 20, color: Colors.white70),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              'New version available',
                              style: TextStyle(fontSize: 13, color: Colors.white),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _label(info.url),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              decoration: TextDecoration.underline,
                              decorationColor: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.arrow_outward, size: 16, color: Colors.white),
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
