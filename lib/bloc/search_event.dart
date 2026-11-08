part of 'search_bloc.dart';

abstract class SearchEvent extends Equatable {
  const SearchEvent();

  @override
  List<Object> get props => [];
}

class SearchTracks extends SearchEvent {
  final String query;

  const SearchTracks(this.query);

  @override
  List<Object> get props => [query];
}

class LoadMoreResults extends SearchEvent {
  const LoadMoreResults();
}

class ClearSearch extends SearchEvent {
  const ClearSearch();

  @override
  List<Object> get props => [];
}
