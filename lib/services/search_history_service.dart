import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The last searches, most recent first.
class SearchHistoryService {
  SearchHistoryService._();
  static final SearchHistoryService instance = SearchHistoryService._();

  final ValueNotifier<List<String>> queries = ValueNotifier<List<String>>(const []);

  Future<void> init() async {
    queries.value = (await SharedPreferences.getInstance()).getStringList('search_history') ?? const [];
  }

  Future<void> add(String query) {
    final q = query.trim();
    if (q.isEmpty) return Future.value();
    return _set([q, ...queries.value.where((x) => x.toLowerCase() != q.toLowerCase())].take(15).toList());
  }

  Future<void> remove(String query) => _set(queries.value.where((x) => x != query).toList());

  Future<void> clear() => _set(const []);

  Future<void> _set(List<String> list) async {
    queries.value = list;
    await (await SharedPreferences.getInstance()).setStringList('search_history', list);
  }
}
