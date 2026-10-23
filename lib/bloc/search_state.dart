part of 'search_bloc.dart';

abstract class SearchState extends Equatable {
  const SearchState();

  @override
  List<Object> get props => [];
}

class SearchInitial extends SearchState {}

class SearchLoading extends SearchState {}

class SearchSuccess extends SearchState {
  final List<Track> tracks;
  final String query;
  final int limit; // how many results were requested from the backend
  final bool hasMore;
  final bool loadingMore;

  const SearchSuccess({
    required this.tracks,
    required this.query,
    required this.limit,
    required this.hasMore,
    this.loadingMore = false,
  });

  SearchSuccess copyWith({bool? loadingMore}) => SearchSuccess(
        tracks: tracks,
        query: query,
        limit: limit,
        hasMore: hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
      );

  @override
  List<Object> get props => [tracks, query, limit, hasMore, loadingMore];
}

class SearchFailure extends SearchState {
  final String message;

  const SearchFailure({required this.message});

  @override
  List<Object> get props => [message];
}
