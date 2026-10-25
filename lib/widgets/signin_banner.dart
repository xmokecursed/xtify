import 'package:flutter/material.dart';
import '../screens/youtube_login_screen.dart';
import '../services/cookie_service.dart';
import '../theme/app_theme.dart';

/// Slim strip at the top of the app: "Your YouTube sign-in expired. Sign in again".
class SignInAgainBanner extends StatelessWidget {
  const SignInAgainBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: CookieService.instance.needsSignInListener,
      builder: (context, needs, _) => AnimatedSize(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        alignment: Alignment.topCenter,
        child: !needs
            ? const SizedBox(width: double.infinity)
            : Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.screen, 8, AppSpacing.screen, 8),
                child: Material(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                        builder: (_) => const YoutubeLoginScreen(),
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppColors.hairline),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.lock_outline_rounded, size: 20, color: Colors.white70),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Your YouTube sign-in expired. Some songs may not play.',
                              style: TextStyle(fontSize: 13, color: Colors.white70),
                            ),
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Sign in again',
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
