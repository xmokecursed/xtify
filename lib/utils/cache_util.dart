class CacheUtil {
  final Map<String, Map<String, dynamic>> _cache = {};

  Map<String, dynamic>? get(String key) {
    if (!_cache.containsKey(key)) {
      return null;
    }

    final item = _cache[key]!;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timestamp = item['timestamp'] as int;
    final expiresIn = item['expiresIn'] as int;

    if (now - timestamp >= expiresIn) {
      _cache.remove(key);
      return null;
    }

    return item;
  }

  void put(String key, Map<String, dynamic> value) {
    _cache[key] = {
      ...value,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
  }

  bool isExpired(Map<String, dynamic> item) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timestamp = item['timestamp'] as int;
    final expiresIn = item['expiresIn'] as int;
    return now - timestamp >= expiresIn;
  }

  void clear() {
    _cache.clear();
  }

  void remove(String key) {
    _cache.remove(key);
  }

  int size() {
    return _cache.length;
  }
}
