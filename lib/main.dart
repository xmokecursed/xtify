import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:xtify_app/bloc/search_bloc.dart';
import 'package:xtify_app/desktop/app_nav.dart';
import 'package:xtify_app/desktop/desktop_keys.dart';
import 'package:xtify_app/desktop/desktop_scope.dart';
import 'package:xtify_app/desktop/desktop_shell.dart';
import 'package:xtify_app/desktop/window_chrome.dart';
import 'package:xtify_app/screens/home_screen.dart';
import 'package:xtify_app/screens/search_screen.dart';
import 'package:xtify_app/screens/library_screen.dart';
import 'package:xtify_app/services/audio_service.dart';
import 'package:xtify_app/services/yt_dlp_update_service.dart';
import 'package:xtify_app/services/audio_url_resolver.dart';
import 'package:xtify_app/services/auto_queue_settings.dart';
import 'package:xtify_app/services/connectivity_service.dart';
import 'package:xtify_app/services/cookie_service.dart';
import 'package:xtify_app/services/cookie_refresh_service.dart';
import 'package:xtify_app/services/history_service.dart';
import 'package:xtify_app/services/artist_mix_service.dart';
import 'package:xtify_app/services/playlist_import_service.dart';
import 'package:xtify_app/services/playlist_service.dart';
import 'package:xtify_app/services/debug_log.dart';
import 'package:xtify_app/services/discord_presence_service.dart';
import 'package:xtify_app/services/download_service.dart';
import 'package:xtify_app/services/feed_service.dart';
import 'package:xtify_app/services/search_history_service.dart';
import 'package:xtify_app/services/update_service.dart' show UpdateService;
import 'package:xtify_app/theme/app_theme.dart';
import 'package:xtify_app/widgets/player_sheet.dart';
import 'package:xtify_app/widgets/signin_banner.dart';
import 'package:xtify_app/widgets/update_banner.dart';

Future<void> main() async {
  if (!isDesktopPlatform) return _start();
  return runZoned(
    _start,
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        parent.print(zone, line);
        XtifyAudioHandler.noteEngineLog(line);
      },
    ),
  );
}

Future<void> _start() async {
  WidgetsFlutterBinding.ensureInitialized();
  DebugLog.install();
  await DebugLog.startSaving();
  PaintingBinding.instance.imageCache.maximumSize = 120;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 60 << 20;
  debugPrint('startup: audio engine');
  JustAudioMediaKit.title = 'Xtify';
  JustAudioMediaKit.ensureInitialized(linux: false);
  
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  
  try {
    debugPrint('startup: audio service');
    await _setupAudioService();
    debugPrint('startup: cookies');
    await CookieService.instance.init();
    debugPrint('startup: connectivity');
    await ConnectivityService.instance.init();
    debugPrint('startup: audio source settings');
    await AudioUrlResolver.loadPreferred();
    debugPrint('startup: queue settings');
    await AutoQueueSettings.instance.init();
    debugPrint('startup: history');
    await HistoryService.instance.init();
    debugPrint('startup: artist mixes');
    await ArtistMixService.instance.init();
    debugPrint('startup: playlists');
    await PlaylistService.instance.init();
    debugPrint('startup: playlist import');
    await PlaylistImportService.instance.init();
    debugPrint('startup: downloads');
    await DownloadService.instance.init();
    debugPrint('startup: search history');
    await SearchHistoryService.instance.init();
    debugPrint('startup: feed');
    await FeedService.instance.init();
    debugPrint('startup: restoring the last track');
    await XtifyAudioHandler.instance.restoreLast();
    if (isDesktopPlatform) await XtifyAudioHandler.instance.restoreVolume();
  } catch (e) {
    debugPrint('Setup error: $e');
    rethrow;
  }
  debugPrint('startup: interface');
  if (isDesktopPlatform) await WindowChrome.instance.init();
  runApp(const XtifyApp());
  debugPrint('startup: ready');
  UpdateService.instance.start();
  if (isDesktopPlatform) DiscordPresenceService.instance.start();
  if (!isDesktopPlatform) {
    AudioUrlResolver.ensureInitialized()
        .then((_) => AudioUrlResolver.ensureModern())
        .catchError((e) {
      debugPrint('Extractor init error (will retry on first use): $e');
    });
  }
  if (ConnectivityService.instance.online.value) {
    FeedService.instance.refreshAll();
  }
  var wasOnline = ConnectivityService.instance.online.value;
  ConnectivityService.instance.online.addListener(() {
    final now = ConnectivityService.instance.online.value;
    if (now && !wasOnline) FeedService.instance.refreshAll();
    wasOnline = now;
  });
  if (!isDesktopPlatform) {
    Future.delayed(const Duration(minutes: 3), YtDlpUpdateService.checkAndUpdate);
  }
  Future.delayed(const Duration(minutes: 1), () => CookieRefreshService.instance.refreshIfOlderThan(const Duration(hours: 12)));
}

class XtifyScrollBehavior extends MaterialScrollBehavior {
  const XtifyScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.trackpad,
      };
}

class XtifyApp extends StatelessWidget {
  const XtifyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SearchBloc(),
      child: MaterialApp(
        navigatorKey: AppNav.instance.rootKey,
        title: 'Xtify',
        theme: buildAppTheme(),
        themeMode: ThemeMode.dark,
        scrollBehavior: const XtifyScrollBehavior(),
        builder: (context, child) {
          final content = child ?? const SizedBox.shrink();
          if (!isDesktopPlatform) return content;
          final size = MediaQuery.sizeOf(context);
          final wide =
              size.width >= kWideMinWidth && size.height >= kWideMinHeight;
          final hidden = size.width < 200 || size.height < 200;
          return Offstage(
            offstage: hidden,
            child: WindowFrame(titleBar: !wide, child: content),
          );
        },
        home: const XtifyHome(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class XtifyHome extends StatefulWidget {
  const XtifyHome({super.key});

  @override
  State<XtifyHome> createState() => _XtifyHomeState();
}

class _XtifyHomeState extends State<XtifyHome> {
  bool? _wide;

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return const _MobileHome();
    return LayoutBuilder(
      builder: (context, constraints) {
        final visible =
            constraints.maxWidth >= 200 && constraints.maxHeight >= 200;
        if (visible || _wide == null) {
          _wide = constraints.maxWidth >= kWideMinWidth &&
              constraints.maxHeight >= kWideMinHeight;
        }
        final wide = _wide!;
        return DesktopScope(
          wide: wide,
          child: DesktopKeyboard(
            child: wide ? const DesktopShell() : const _MobileHome(),
          ),
        );
      },
    );
  }
}

class _MobileHome extends StatefulWidget {
  const _MobileHome();

  @override
  State<_MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<_MobileHome>
    with SingleTickerProviderStateMixin {
  int _selectedIndex = AppNav.instance.tab.value;
  final ValueNotifier<bool> _playerOpen = ValueNotifier<bool>(false);
  late final AnimationController _fadeCtl = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
    value: 1,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _fadeCtl, curve: AppMotion.curve);

  @override
  void initState() {
    super.initState();
    AppNav.instance.tab.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    AppNav.instance.tab.removeListener(_onTabChanged);
    _playerOpen.dispose();
    _fadeCtl.dispose();
    super.dispose();
  }

  static const List<Widget> _widgetOptions = <Widget>[
    HomeScreen(),
    SearchScreen(),
    LibraryScreen(),
  ];

  void _onTabChanged() {
    final index = AppNav.instance.tab.value;
    if (!mounted || index == _selectedIndex) return;
    _fadeCtl.forward(from: 0.35);
    setState(() {
      _selectedIndex = index;
    });
  }

  void _onItemTapped(int index) {
    AppNav.instance.tab.value = index;
  }

  bool _trackPlayer(DraggableScrollableNotification n) {
    _playerOpen.value = n.extent > n.minExtent + kPlayerSettle;
    return false;
  }

  void _onBack(bool didPop, Object? result) {
    if (didPop || _playerOpen.value) return;
    AppNav.instance.tab.value = AppNav.homeTab;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _playerOpen,
      builder: (context, open, child) => PopScope(
        canPop: !open && _selectedIndex == AppNav.homeTab,
        onPopInvokedWithResult: _onBack,
        child: child!,
      ),
      child: Scaffold(
        body: Stack(
          children: [
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  const SignInAgainBanner(),
                  const UpdateBanner(),
                  Expanded(
                    child: FadeTransition(
                      opacity: _fade,
                      child: IndexedStack(
                        index: _selectedIndex,
                        children: _widgetOptions,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            NotificationListener<DraggableScrollableNotification>(
              onNotification: _trackPlayer,
              child: PlayerSheet(),
            ),
          ],
        ),
        bottomNavigationBar: DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.hairline)),
          ),
          child: NavigationBar(
            selectedIndex: _selectedIndex,
            onDestinationSelected: _onItemTapped,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.search_rounded),
                selectedIcon: Icon(Icons.search_rounded, weight: 700),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music_rounded),
                label: 'Library',
              ),
            ],
          ),
        ),
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
