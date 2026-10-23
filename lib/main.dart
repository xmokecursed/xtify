import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:xtify_app/screens/home_screen.dart';
import 'package:xtify_app/screens/search_screen.dart';
import 'package:xtify_app/screens/library_screen.dart';
import 'package:xtify_app/services/audio_service.dart';
import 'package:xtify_app/services/yt_dlp_update_service.dart';
import 'package:xtify_app/services/audio_url_resolver.dart';
import 'package:xtify_app/services/cookie_service.dart';
import 'package:xtify_app/services/cookie_refresh_service.dart';
import 'package:xtify_app/services/history_service.dart';
import 'package:xtify_app/services/playlist_service.dart';
import 'package:xtify_app/services/download_service.dart';
import 'package:xtify_app/services/feed_service.dart';
import 'package:xtify_app/services/search_history_service.dart';
import 'package:xtify_app/theme/app_theme.dart';
import 'package:xtify_app/widgets/player_sheet.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep decoded thumbnails in RAM small
  PaintingBinding.instance.imageCache.maximumSize = 120;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 60 << 20;
  try {
    await _setupAudioService();
    // Initialize cookie service
    await CookieService.instance.init();
    await AudioUrlResolver.loadPreferred();
    await HistoryService.instance.init();
    await PlaylistService.instance.init();
    await DownloadService.instance.init(); // after playlists: keeps Downloads in step
    await SearchHistoryService.instance.init();
    await FeedService.instance.init(); // cached lists, instant on screen
    await XtifyAudioHandler.instance.restoreLast(); // last song, paused where you left off
  } catch (e) {
    debugPrint('Setup error: $e');
    rethrow;
  }
  runApp(const XtifyApp());
  // Initialize extractor in background (don't await)
  AudioUrlResolver.ensureInitialized().catchError((e) {
    debugPrint('Extractor init error (will retry on first use): $e');
  });
  // Refresh home feeds in the background (cached for 6 hours)
  FeedService.instance.refreshAll(); // one after the other, to go easy on the server
  // Check for yt-dlp updates in background (don't await)
  Future.delayed(const Duration(minutes: 3), YtDlpUpdateService.checkAndUpdate);
  Future.delayed(const Duration(minutes: 1), () => CookieRefreshService.instance.refreshIfOlderThan(const Duration(hours: 12)));
}

class XtifyApp extends StatelessWidget {
  const XtifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Xtify',
      theme: buildAppTheme(),
      themeMode: ThemeMode.dark,
      home: const XtifyHome(),
    );
  }
}

class XtifyHome extends StatefulWidget {
  const XtifyHome({super.key});

  @override
  State<XtifyHome> createState() => _XtifyHomeState();
}

class _XtifyHomeState extends State<XtifyHome> {
  int _selectedIndex = 0;

  static const List<Widget> _widgetOptions = <Widget>[
    HomeScreen(),
    SearchScreen(),
    LibraryScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Main content
          SafeArea(
            bottom: false,
            child: IndexedStack(
              index: _selectedIndex,
              children: _widgetOptions,
            ),
          ),
          // Player sheet at the bottom
          PlayerSheet(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.search_outlined),
            label: 'Search',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.library_music_outlined),
            label: 'Library',
          ),
        ],
      ),
    );
  }
}

Future<void> _setupAudioService() async {
  await AudioService.init(
    builder: () => XtifyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.xmokecursed.xtify.app.channel',
      androidNotificationChannelName: 'Xtify Music',
      androidNotificationOngoing: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );
}