import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/cookie_service.dart';

class YoutubeLoginScreen extends StatefulWidget {
  const YoutubeLoginScreen({super.key});

  @override
  State<YoutubeLoginScreen> createState() => _YoutubeLoginScreenState();
}

class _YoutubeLoginScreenState extends State<YoutubeLoginScreen> {
  final CookieService _cookieService = CookieService.instance;
  bool _hasSavedCookies = false;

  @override
  void initState() {
    super.initState();
    _hasSavedCookies = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // AppBar with close button
            AppBar(
              backgroundColor: Colors.black,
              leading: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () {
                  Navigator.of(context).pop(false);
                },
              ),
              title: const Text(
                'Sign in to YouTube',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
            ),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(
                  url: WebUri(
                    'https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F',
                  ),
                ),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  userAgent:
                      'Mozilla/5.0 (Linux; Android 12; SM-G998N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36',
                ),
                onLoadStop: (controller, url) async {
                  await _checkSignIn(controller, url);
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  await _checkSignIn(controller, url);
                },
                onReceivedError: (controller, url, error) {
                  if (kDebugMode) {
                    debugPrint('WebView load error: $url - $error');
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkSignIn(InAppWebViewController controller, Object? url) async {
    if (_hasSavedCookies) return;

    final uri = Uri.tryParse(url?.toString() ?? '');
    if (uri == null) return;

    // Mobile user agent lands on m.youtube.com, not www.youtube.com
    final host = uri.host;
    final isYouTube = host == 'youtube.com' || host.endsWith('.youtube.com');
    if (!isYouTube) return;

    if (!await _cookieService.hasAuthCookieInWebView()) return;

    _hasSavedCookies = true; // set first so both callbacks don't save twice
    try {
      await _cookieService.saveFromWebView();
    } catch (e) {
      _hasSavedCookies = false;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save sign-in: $e')),
        );
      }
      return;
    }
    
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }
}
