import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/search_bloc.dart';
import '../screens/home_screen.dart';
import '../screens/library_screen.dart';
import '../screens/search_screen.dart';
import '../services/audio_service.dart';
import '../services/playlist_service.dart';
import '../services/search_history_service.dart';
import '../theme/app_theme.dart';
import '../widgets/download_widgets.dart';
import '../widgets/layout.dart';
import '../widgets/pressable.dart';
import '../widgets/signin_banner.dart';
import 'app_nav.dart';
import 'desktop_keys.dart';
import 'desktop_player_bar.dart';
import 'desktop_scope.dart';
import 'now_playing_panel.dart';
import 'window_chrome.dart';

class DesktopShell extends StatefulWidget {
  const DesktopShell({super.key});

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final ValueNotifier<int> _plays = XtifyAudioHandler.instance.userPlays;

  @override
  void initState() {
    super.initState();
    _plays.addListener(_openNowPlaying);
  }

  @override
  void dispose() {
    _plays.removeListener(_openNowPlaying);
    super.dispose();
  }

  void _openNowPlaying() {
    AppNav.instance.nowPlayingOpen.value = true;
  }

  @override
  Widget build(BuildContext context) {
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: const Scaffold(
        backgroundColor: Colors.black,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Region(order: 1, child: DesktopSidebar()),
            Expanded(
              child: Column(
                children: [
                  _Region(order: 2, child: DesktopTopBar()),
                  SignInAgainBanner(),
                  Expanded(child: _Content()),
                  _Banners(),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: _Region(order: 5, child: DesktopPlayerBar()),
      ),
    );
  }
}

class _Region extends StatelessWidget {
  final double order;
  final Widget child;

  const _Region({required this.order, required this.child});

  @override
  Widget build(BuildContext context) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(order),
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: child,
      ),
    );
  }
}

class _Banners extends StatelessWidget {
  const _Banners();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [DownloadBanner(), SignInStrip()],
      ),
    );
  }
}

class _Content extends StatelessWidget {
  const _Content();

  @override
  Widget build(BuildContext context) {
    final nav = AppNav.instance;
    final base = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Theme(
        data: base.copyWith(
          scaffoldBackgroundColor: AppColors.surface,
          appBarTheme: base.appBarTheme.copyWith(backgroundColor: AppColors.surface),
        ),
        child: SpaceTogglesPlayback(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ColoredBox(
              color: AppColors.surface,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _Region(
                      order: 3,
                      child: HeroControllerScope.none(
                        child: Navigator(
                          key: nav.contentKey,
                          observers: [nav.observer],
                          onGenerateRoute: (settings) => MaterialPageRoute<void>(
                            settings: settings,
                            builder: (_) => const _TabsPage(),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: nav.nowPlayingOpen,
                    builder: (_, open, _) => TweenAnimationBuilder<double>(
                      tween: Tween<double>(end: open ? 1.0 : 0.0),
                      duration: AppMotion.medium,
                      curve: AppMotion.curve,
                      child: const _Region(order: 4, child: NowPlayingPanel()),
                      builder: (context, t, child) => t == 0
                          ? const SizedBox.shrink()
                          : ClipRect(
                              child: Align(
                                alignment: Alignment.centerRight,
                                widthFactor: t,
                                child: child,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabsPage extends StatelessWidget {
  const _TabsPage();

  static const List<Widget> _pages = <Widget>[
    HomeScreen(),
    SearchScreen(),
    LibraryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppNav.instance.tab,
      builder: (context, tab, _) => IndexedStack(
        index: tab,
        children: [
          for (var i = 0; i < _pages.length; i++)
            ExcludeFocus(excluding: i != tab, child: _pages[i]),
        ],
      ),
    );
  }
}

class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = AppNav.instance;
    return SizedBox(
      width: 76,
      child: Column(
        children: [
          const WindowDragArea(
            child: SizedBox(
              width: double.infinity,
              height: 74,
              child: Center(child: XtifyLogo(size: 40)),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: nav.tab,
            builder: (context, tab, _) => Column(
              children: [
                _NavItem(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  label: 'Home (Ctrl+1)',
                  selected: tab == AppNav.homeTab,
                  onTap: () => nav.goTab(AppNav.homeTab),
                ),
                _NavItem(
                  icon: Icons.search_rounded,
                  label: 'Search (Ctrl+K)',
                  selected: tab == AppNav.searchTab,
                  onTap: nav.focusSearch,
                ),
                _NavItem(
                  icon: Icons.library_music_outlined,
                  selectedIcon: Icons.library_music_rounded,
                  label: 'Library (Ctrl+3)',
                  selected: tab == AppNav.libraryTab,
                  onTap: () => nav.goTab(AppNav.libraryTab),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10, horizontal: 20),
            child: Divider(height: 1),
          ),
          _NavItem(
            icon: Icons.favorite_border_rounded,
            label: 'Favourites',
            selected: false,
            onTap: () => nav.openPlaylist(PlaylistService.favouritesId),
          ),
          _NavItem(
            icon: Icons.download_done_rounded,
            label: 'Downloads',
            selected: false,
            onTap: () => nav.openPlaylist(PlaylistService.downloadsId),
          ),
          const Spacer(),
          _NavItem(
            icon: Icons.keyboard_alt_outlined,
            label: 'Keyboard shortcuts (?)',
            selected: false,
            onTap: () => showShortcutsHelp(context),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData? selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedIcon,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 400),
        child: Pressable(
          scale: 0.94,
          focusRadius: 12,
          hoverTint: !selected,
          debounce: const Duration(milliseconds: 150),
          onTap: onTap,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: selected ? const Color(0x24FFFFFF) : null,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              selected ? (selectedIcon ?? icon) : icon,
              size: 26,
              color: selected ? Colors.white : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class DesktopTopBar extends StatelessWidget {
  const DesktopTopBar({super.key});

  @override
  Widget build(BuildContext context) {
    final nav = AppNav.instance;
    final controlsWidth =
        WindowChrome.instance.active.value ? WindowControls.width : 0.0;
    return Stack(
      children: [
        const Positioned.fill(child: WindowDragArea()),
        Padding(
          padding: EdgeInsets.fromLTRB(
            8,
            10,
            controlsWidth > 0 ? controlsWidth + 8 : 16,
            10,
          ),
          child: Row(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: nav.canGoBackNotifier,
                builder: (context, can, _) => IconButton(
                  tooltip: 'Back (Esc)',
                  onPressed: can ? nav.back : null,
                  icon: const Icon(Icons.chevron_left_rounded, size: 26),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.card,
                    disabledBackgroundColor: AppColors.card,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: AppColors.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 560),
                    child: DesktopSearchField(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              IconButton(
                tooltip: 'Refresh home (F5)',
                onPressed: nav.refreshFeed,
                icon: const Icon(Icons.refresh_rounded, size: 22),
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.card,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class DesktopSearchField extends StatefulWidget {
  const DesktopSearchField({super.key});

  @override
  State<DesktopSearchField> createState() => _DesktopSearchFieldState();
}

class _DesktopSearchFieldState extends State<DesktopSearchField> {
  final AppNav _nav = AppNav.instance;

  @override
  void initState() {
    super.initState();
    _nav.searchController.addListener(_rebuild);
    _nav.searchFocus.addListener(_rebuild);
  }

  @override
  void dispose() {
    _nav.searchController.removeListener(_rebuild);
    _nav.searchFocus.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _changed(String value) {
    if (value.trim().isEmpty) {
      context.read<SearchBloc>().add(const ClearSearch());
      return;
    }
    if (_nav.tab.value != AppNav.searchTab || _nav.canGoBack) {
      _nav.goTab(AppNav.searchTab);
    }
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty) return;
    SearchHistoryService.instance.add(query);
    context.read<SearchBloc>().add(SearchTracks(query));
    _nav.goTab(AppNav.searchTab);
  }

  void _clear() {
    _nav.searchController.clear();
    context.read<SearchBloc>().add(const ClearSearch());
    _nav.searchFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _nav.searchFocus.hasFocus;
    OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
          borderSide: BorderSide(color: color, width: width),
        );
    return TextField(
      controller: _nav.searchController,
      focusNode: _nav.searchFocus,
      textInputAction: TextInputAction.search,
      onChanged: _changed,
      onSubmitted: _submit,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: focused ? AppColors.border : AppColors.card,
        hintText: 'Search songs or artists  (Ctrl+K)',
        hintStyle: const TextStyle(color: AppColors.textSecondary, fontSize: 14.5),
        prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textSecondary),
        prefixIconConstraints: const BoxConstraints(minWidth: 48, minHeight: 40),
        suffixIcon: _nav.searchController.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close_rounded,
                    size: 18, color: AppColors.textSecondary),
                onPressed: _clear,
              ),
        suffixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: border(Colors.transparent, 1),
        enabledBorder: border(Colors.transparent, 1),
        focusedBorder: border(Colors.white54, 1.5),
      ),
    );
  }
}
