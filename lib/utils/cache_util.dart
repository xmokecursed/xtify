class CacheUtil {
  final Map<String, Map<String, dynamic>> _cache = {};

  /// Gets a cached item if it exists and is not expired.
  /// Returns null if not found or expired.
  Map<String, dynamic>? get(String key) {
    if (!_cache.containsKey(key)) {
      return null;
    }

    final item = _cache[key]!;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timestamp = item['timestamp'] as int;
    final expiresIn = item['expiresIn'] as int;

    if (now - timestamp >= expiresIn) {
      // Remove expired item
      _cache.remove(key);
      return null;
    }

    return item;
  }

  /// Stores an item in the cache.
  void put(String key, Map<String, dynamic> value) {
    _cache[key] = {
      ...value,
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
  }

  /// Checks if a cached item is expired.
  /// Returns true if not found or expired.
  bool isExpired(Map<String, dynamic> item) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final timestamp = item['timestamp'] as int;
    final expiresIn = item['expiresIn'] as int;
    return now - timestamp >= expiresIn;
  }

  /// Clears all cached items.
  void clear() {
    _cache.clear();
  }

  /// Removes a specific cached item.
  void remove(String key) {
    _cache.remove(key);
  }

  /// Returns the number of items in the cache.
  int size() {
    return _cache.length;
  }
}