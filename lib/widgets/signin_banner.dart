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

/// Slim card that floats just above the mini player while nobody is signed in to YouTube.
///
/// Songs play without a sign-in, but YouTube refuses some requests that do not look like a
/// signed-in person ("Sign in to confirm you're not a bot"). So signing in stays on offer, as
/// this strip, and never takes the place of the player. It goes away by itself once the sign-in
/// is saved, and the player sheet hides it while the player is pulled up.
class SignInStrip extends StatelessWidget {
  const SignInStrip({super.key});

  Future<void> _signIn(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => const YoutubeLoginScreen(),
      ),
    );
    if (ok == true) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Signed in to YouTube')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: CookieService.instance.signedInListener,
      builder: (context, signedIn, _) => AnimatedSize(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        alignment: Alignment.bottomCenter,
        child: signedIn
            ? const SizedBox(width: double.infinity)
            : Padding(
                // the gap to whatever floats above it (the download card)
                padding: const EdgeInsets.only(top: 8),
                child: Material(
                  color: AppColors.card,
                  borderRadius: BorderRadius.circular(14),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => _signIn(context),
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
                              'Sign in to YouTube so more songs play',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: Colors.white70),
                            ),
                          ),
                          SizedBox(width: 12),
                          Text(
                            'Sign in',
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
