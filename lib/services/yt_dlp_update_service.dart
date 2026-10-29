import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:extractor/extractor.dart';
import 'package:flutter/foundation.dart';
import '../services/audio_url_resolver.dart';

class YtDlpUpdateService {
  static const String _lastUpdateKey = 'yt_dlp_last_update';
  static const Duration _updateInterval = Duration(hours: 24);

  /// Checks if yt-dlp update is needed and performs update if so.
  /// This method should be called at app startup.
  /// It never throws; errors are logged and ignored as per requirements.
  static Future<void> checkAndUpdate() async {
    try {
      // Wait for extractor to be initialized (but don't block indefinitely if it fails)
      await AudioUrlResolver.ensureInitialized().timeout(const Duration(seconds: 10), onTimeout: () {
        debugPrint('Extractor init timeout during update check; skipping update');
        throw TimeoutException('Extractor init timeout');
      });

      // updating uses the CPU for a while: never while a song is being looked up
      for (var i = 0; i < 20 && AudioUrlResolver.isBusy; i++) {
        await Future.delayed(const Duration(seconds: 15));
      }

      final prefs = await SharedPreferences.getInstance();
      final lastUpdate = prefs.getInt(_lastUpdateKey);
      final now = DateTime.now().millisecondsSinceEpoch;

      if (lastUpdate == null || now - lastUpdate >= _updateInterval.inMilliseconds) {
        // Attempt to update yt-dlp binary via extractor plugin
        try {
          final result = await YoutubeDLFlutter.instance.updateYoutubeDL();
          if (result.status == OperationStatus.success) {
            await prefs.setInt(_lastUpdateKey, now);
            await AudioUrlResolver.rememberVersion(result.version);
            debugPrint('yt-dlp updated, version: ${result.version}');
          } else {
            debugPrint('yt-dlp update failed: ${result.errorMessage}');
          }
        } on Exception catch (e) {
          // Update failed - we must not block or crash the app
          debugPrint('yt-dlp update failed: $e');
        }
      }
    } on Exception catch (e) {
      // Any error in checking/update should not crash the app
      debugPrint('Error during yt-dlp update check: $e');
    }
  }
}
