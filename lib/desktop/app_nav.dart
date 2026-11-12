import 'package:flutter/material.dart';
import '../screens/playlist_screen.dart';
import '../screens/queue_screen.dart';
import '../services/feed_service.dart';

class _RouteWatcher extends NavigatorObserver {
  final VoidCallback onChange;

  _RouteWatcher(this.onChange);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => onChange();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => onChange();
}

class AppNav {
  AppNav._();
  static final AppNav instance = AppNav._();

  static const int homeTab = 0;
  static const int searchTab = 1;
  static const int libraryTab = 2;

  final GlobalKey<NavigatorState> rootKey = GlobalKey<NavigatorState>();
  final GlobalKey<NavigatorState> contentKey = GlobalKey<NavigatorState>();
  final ValueNotifier<int> tab = ValueNotifier<int>(homeTab);
  final ValueNotifier<bool> nowPlayingOpen = ValueNotifier<bool>(false);
  final ValueNotifier<bool> canGoBackNotifier = ValueNotifier<bool>(false);
  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocus = FocusNode(debugLabel: 'Xtify search');
  late final NavigatorObserver observer = _RouteWatcher(_syncBack);

  NavigatorState? get navigator => contentKey.currentState ?? rootKey.currentState;

  Route<dynamic>? topRoute() {
    Route<dynamic>? top;
    navigator?.popUntil((route) {
      top = route;
      return true;
    });
    return top;
  }

  bool get topIsPage {
    final r = topRoute();
    return r == null || r is PageRoute;
  }

  bool get canGoBack {
    final nav = navigator;
    return nav != null && nav.canPop();
  }

  void back() {
    final nav = navigator;
    if (nav != null && nav.canPop()) nav.pop();
  }

  void popToFirst() {
    final nav = navigator;
    if (nav != null && nav.canPop()) nav.popUntil((route) => route.isFirst);
  }

  void goTab(int index) {
    popToFirst();
    tab.value = index;
  }

  void focusSearch() {
    goTab(searchTab);
    _afterFrame(() {
      searchFocus.requestFocus();
      searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: searchController.text.length,
      );
    });
  }

  void openPlaylist(String id) {
    popToFirst();
    navigator?.push(
      MaterialPageRoute<void>(builder: (_) => PlaylistScreen(playlistId: id)),
    );
  }

  void toggleQueue() {
    final nav = navigator;
    if (nav == null) return;
    final top = topRoute();
    if (top != null && top.settings.name == 'queue') {
      nav.pop();
      return;
    }
    nav.push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'queue'),
        builder: (_) => const QueueScreen(),
      ),
    );
  }

  void toggleNowPlaying() {
    nowPlayingOpen.value = !nowPlayingOpen.value;
  }

  void refreshFeed() {
    FeedService.instance.refreshAll(force: true).catchError((Object e) {
      debugPrint('home refresh failed: $e');
    });
  }

  void _syncBack() {
    _afterFrame(() {
      final nav = contentKey.currentState;
      final can = nav != null && nav.canPop();
      if (canGoBackNotifier.value != can) canGoBackNotifier.value = can;
    });
  }

  void _afterFrame(VoidCallback action) {
    WidgetsBinding.instance.addPostFrameCallback((_) => action());
    WidgetsBinding.instance.ensureVisualUpdate();
  }
}
