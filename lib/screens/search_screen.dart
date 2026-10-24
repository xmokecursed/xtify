import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:xtify_app/bloc/search_bloc.dart';
import 'package:xtify_app/models/playlist_model.dart';
import 'package:xtify_app/screens/playlist_screen.dart';
import 'package:xtify_app/services/playlist_service.dart';
import 'package:xtify_app/services/search_history_service.dart';
import 'package:xtify_app/theme/app_theme.dart';
import 'package:xtify_app/widgets/layout.dart';
import 'package:xtify_app/widgets/media_tile.dart';
import 'package:xtify_app/widgets/offline_banner.dart';
import 'package:xtify_app/widgets/track_row.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SearchBloc(),
      child: BlocBuilder<SearchBloc, SearchState>(
        builder: (context, state) {
          return CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: ScreenHeader(title: 'Search')),
              const SliverToBoxAdapter(child: OfflineBanner()),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.screen, 0, AppSpacing.screen, 16),
                  child: SearchBarWidget(
                    controller: _controller,
                    focusNode: _focus,
                    onSubmitted: (query) {
                      SearchHistoryService.instance.add(query);
                      context.read<SearchBloc>().add(SearchTracks(query));
                    },
                    onSearchCleared: () {
                      context.read<SearchBloc>().add(const ClearSearch());
                    },
                  ),
                ),
              ),
              if (state is SearchLoading)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(48),
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                  ),
                )
              else if (state is SearchFailure)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.screen, vertical: 40),
                    child: Column(
                      children: [
                        Icon(Icons.error_outline,
                            color: AppColors.textSecondary, size: 44),
                        SizedBox(height: 14),
                        Text(
                          'Search failed',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Check your connection and try again.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                )
              else if (state is SearchSuccess) ...[
                if (PlaylistService.instance.search(state.query).isNotEmpty)
                  SliverToBoxAdapter(child: _PlaylistResults(query: state.query)),
                if (state.tracks.isEmpty)
                  const SliverToBoxAdapter(child: EmptyHint(text: 'No songs found'))
                else
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => TrackRow(track: state.tracks[index]),
                      childCount: state.tracks.length,
                    ),
                  ),
                SliverToBoxAdapter(child: _LoadMoreFooter(state: state)),
              ]
              else
                SliverToBoxAdapter(
                  child: _RecentSearches(onPick: (q) {
                    _controller.text = q;
                    _focus.unfocus();
                    SearchHistoryService.instance.add(q);
                    context.read<SearchBloc>().add(SearchTracks(q));
                  }),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// "Load more" button (or spinner) under the song list.
class _LoadMoreFooter extends StatelessWidget {
  final SearchSuccess state;
  const _LoadMoreFooter({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 140),
      child: Center(
        child: state.loadingMore
            ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
              )
            : state.hasMore && state.tracks.isNotEmpty
                ? OutlinedButton(
                    onPressed: () =>
                        context.read<SearchBloc>().add(const LoadMoreResults()),
                    child: const Text('Load more'),
                  )
                : const SizedBox.shrink(),
      ),
    );
  }
}

/// The user's own playlists that match the search.
class _PlaylistResults extends StatelessWidget {
  final String query;
  const _PlaylistResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Playlist>>(
      valueListenable: PlaylistService.instance.playlists,
      builder: (context, _, _) {
        final matches = PlaylistService.instance.search(query);
        if (matches.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.section),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(title: 'Playlists'),
              HList(
                height: 200,
                itemCount: matches.length,
                itemBuilder: (context, i) {
                  final p = matches[i];
                  return MediaTile(
                    title: p.title,
                    subtitle: '${p.tracks.length} songs',
                    imageUrl: p.imageUrl,
                    fallbackIcon: p.id == PlaylistService.favouritesId
                        ? Icons.favorite
                        : p.id == PlaylistService.downloadsId
                            ? Icons.download_done
                            : Icons.queue_music,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlaylistScreen(playlistId: p.id),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.section),
              const SectionHeader(title: 'Songs'),
            ],
          ),
        );
      },
    );
  }
}

class SearchBarWidget extends StatefulWidget {
  final void Function(String) onSubmitted;
  final void Function()? onSearchCleared;

  final TextEditingController controller;
  final FocusNode focusNode;

  const SearchBarWidget({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    this.onSearchCleared,
  });

  @override
  State<SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<SearchBarWidget> {
  TextEditingController get _controller => widget.controller;
  FocusNode get _focus => widget.focusNode;

  void _onChanged() {
    if (mounted) setState(() {}); // show/hide the X, focus outline
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    _focus.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _focus.removeListener(_onChanged);
    super.dispose();
  }

  void _submit(String value) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) widget.onSubmitted(trimmed);
    _focus.unfocus();
  }

  void _clear() {
    _controller.clear();
    widget.onSearchCleared?.call();
    _focus.requestFocus(); // keep the keyboard open for a new query
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppMotion.fast,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: AppColors.card,
        border: Border.all(
          color: _focus.hasFocus ? Colors.white24 : AppColors.hairline,
        ),
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        onSubmitted: _submit,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search for songs or artists',
          hintStyle: const TextStyle(color: AppColors.textSecondary),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          prefixIcon: const Icon(Icons.search_rounded, color: AppColors.textSecondary),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, color: AppColors.textSecondary),
                  onPressed: _clear,
                ),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
    );
  }
}

class _RecentSearches extends StatelessWidget {
  final void Function(String) onPick;
  const _RecentSearches({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: SearchHistoryService.instance.queries,
      builder: (context, list, _) {
        if (list.isEmpty) return const EmptyHint(text: 'Search for songs and artists.');
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Recent searches',
              trailing: TextButton(
                onPressed: SearchHistoryService.instance.clear,
                child: const Text('Clear all'),
              ),
            ),
            for (final q in list)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.screen),
                leading: const Icon(Icons.history, color: AppColors.textSecondary),
                title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 20, color: AppColors.textSecondary),
                  onPressed: () => SearchHistoryService.instance.remove(q),
                ),
                onTap: () => onPick(q),
              ),
            const SizedBox(height: 140),
          ],
        );
      },
    );
  }
}
