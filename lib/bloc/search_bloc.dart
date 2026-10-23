import 'dart:math';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:rxdart/rxdart.dart';
import '../../models/track_model.dart';
import '../../services/api_service.dart';
import '../../services/audio_url_resolver.dart';

part 'search_event.dart';
part 'search_state.dart';

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  static const int _firstLimit = 25; // ~15-20 left after filtering
  static const int _step = 20;
  static const int _maxLimit = 50;

  SearchBloc() : super(SearchInitial()) {
    on<SearchTracks>(
      _onSearchTracks,
      transformer: (events, mapper) => events.switchMap(mapper),
    );
    on<LoadMoreResults>(_onLoadMore);
    on<ClearSearch>(_onClearSearch);
  }

  Future<void> _onSearchTracks(
      SearchTracks event, Emitter<SearchState> emit) async {
    final query = event.query.trim();
    if (query.isEmpty) {
      emit(SearchInitial());
      return;
    }

    emit(SearchLoading());
    try {
      final tracks = await ApiService.searchTracks(query, limit: _firstLimit);
      emit(SearchSuccess(
        tracks: tracks,
        query: query,
        limit: _firstLimit,
        hasMore: tracks.isNotEmpty,
      ));
      if (tracks.isNotEmpty) AudioUrlResolver.prefetch(tracks.first.id);
    } catch (e) {
      emit(SearchFailure(message: e.toString()));
    }
  }

  Future<void> _onLoadMore(
      LoadMoreResults event, Emitter<SearchState> emit) async {
    final current = state;
    if (current is! SearchSuccess || current.loadingMore || !current.hasMore) {
      return;
    }
    emit(current.copyWith(loadingMore: true));

    final newLimit = min(current.limit + _step, _maxLimit);
    try {
      final tracks = await ApiService.searchTracks(current.query, limit: newLimit);
      final latest = state;
      // The user searched for something else meanwhile: drop this batch.
      if (latest is! SearchSuccess || latest.query != current.query) return;

      final merged = <Track>[...current.tracks];
      final seen = merged.map((t) => t.id).toSet();
      for (final t in tracks) {
        if (seen.add(t.id)) merged.add(t);
      }
      final gotNew = merged.length > current.tracks.length;
      emit(SearchSuccess(
        tracks: merged,
        query: current.query,
        limit: newLimit,
        hasMore: gotNew && newLimit < _maxLimit,
      ));
    } catch (_) {
      final latest = state;
      if (latest is SearchSuccess && latest.query == current.query) {
        emit(latest.copyWith(loadingMore: false)); // keep results, allow retry
      }
    }
  }

  void _onClearSearch(ClearSearch event, Emitter<SearchState> emit) {
    emit(SearchInitial());
  }
}
