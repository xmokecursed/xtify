import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/playlist_model.dart';
import '../models/track_model.dart';
import 'data_merge.dart';
import 'vault.dart';

class PlaylistService {
  PlaylistService._();
  static final PlaylistService instance = PlaylistService._();
  static const String favouritesId = 'favourites';
  static const String downloadsId = 'downloads';

  final ValueNotifier<List<Playlist>> playlists =
      ValueNotifier<List<Playlist>>(const []);
  static const String _vaultName = 'playlists';
  bool _started = false;

  Future<void> init() async {
    String? text;
    var readable = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final old = File('${dir.path}${Platform.pathSeparator}playlists.json');
      text = await Vault.instance.readTextOrMove(
        _vaultName,
        old,
        isValid: Vault.isJsonList,
        merge: DataMerge.playlists,
      );
    } catch (e) {
      // Not knowing what is saved is not the same as nothing being saved, so
      // nothing is saved over it.
      debugPrint('playlists could not be fetched: $e');
      readable = false;
      Vault.instance.noteUnreadable('playlists');
    }
    if (text != null) {
      try {
        final data = json.decode(text) as List<dynamic>;
        playlists.value = data
            .map((e) => Playlist.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        // Saved data that cannot be read is never saved over. A version that
        // understands it finds it exactly as it was.
        debugPrint('playlists load failed: $e');
        readable = false;
        Vault.instance.noteUnreadable('playlists');
      }
    }
    _started = readable;
    await _ensureFavourites();
  }

  Future<void> _ensureFavourites() async {
    final list = [...playlists.value];
    Playlist builtIn(String id, String title) => Playlist(
          id: id,
          title: title,
          imageUrl: '',
          ownerId: 'local',
          createdAt: DateTime.now(),
          tracks: const [],
        );
    var changed = false;
    if (!list.any((p) => p.id == favouritesId)) {
      list.insert(0, builtIn(favouritesId, 'Favourites'));
      changed = true;
    }
    if (!list.any((p) => p.id == downloadsId)) {
      final at = list.indexWhere((p) => p.id == favouritesId) + 1;
      list.insert(at, builtIn(downloadsId, 'Downloads'));
      changed = true;
    }
    if (!changed) return;
    playlists.value = list;
    await _save();
  }

  List<Playlist> get userPlaylists => playlists.value
      .where((p) => p.id != favouritesId && p.id != downloadsId)
      .toList();

  bool isFavourite(String trackId) =>
      byId(favouritesId)?.tracks.any((t) => t.id == trackId) ?? false;

  final Set<String> _favBusy = {};

  Future<bool> toggleFavourite(Track t) async {
    if (!_favBusy.add(t.id)) return isFavourite(t.id);
    try {
      if (isFavourite(t.id)) {
        await removeTrack(favouritesId, t.id);
        return false;
      }
      await addTrack(favouritesId, t);
      return true;
    } finally {
      _favBusy.remove(t.id);
    }
  }

  Playlist? byId(String id) {
    for (final p in playlists.value) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<Playlist> create(String title) async {
    final p = Playlist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? 'New playlist' : title.trim(),
      imageUrl: '',
      ownerId: 'local',
      createdAt: DateTime.now(),
      tracks: const [],
    );
    playlists.value = [...playlists.value, p];
    await _save();
    return p;
  }

  Future<Playlist> createFrom(
    String title,
    List<Track> tracks, {
    String description = '',
  }) async {
    final base = Playlist(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: title.trim().isEmpty ? 'Imported playlist' : title.trim(),
      description: description,
      imageUrl: '',
      ownerId: 'local',
      createdAt: DateTime.now(),
      tracks: const [],
    );
    final made = _copy(base, tracks: tracks);
    playlists.value = [...playlists.value, made];
    await _save();
    return made;
  }

  Future<void> setTracks(String id, List<Track> tracks) async {
    if (byId(id) == null) return;
    await _update(id, (p) => _copy(p, tracks: tracks));
  }

  Future<void> rename(String id, String title) async {
    final t = title.trim();
    if (t.isEmpty || id == favouritesId || id == downloadsId) return;
    await _update(id, (p) => _copy(p, title: t));
  }

  Future<void> delete(String id) async {
    if (id == favouritesId || id == downloadsId) return;
    playlists.value = playlists.value.where((p) => p.id != id).toList();
    await _save();
  }
  Future<bool> addTrack(String id, Track t) async {
    final p = byId(id);
    if (p == null || p.tracks.any((x) => x.id == t.id)) return false;
    await _update(id, (p) => _copy(p, tracks: [...p.tracks, t]));
    return true;
  }

  Future<void> removeTrack(String id, String trackId) async {
    await _update(
      id,
      (p) => _copy(p, tracks: p.tracks.where((t) => t.id != trackId).toList()),
    );
  }

  Future<void> insertTrack(String id, Track t, int index) async {
    final p = byId(id);
    if (p == null || p.tracks.any((x) => x.id == t.id)) return;
    await _update(id, (p) {
      final list = [...p.tracks];
      list.insert(index.clamp(0, list.length), t);
      return _copy(p, tracks: list);
    });
  }
  Future<void> reorder(String id, int oldIndex, int newIndex) async {
    await _update(id, (p) {
      final list = [...p.tracks];
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
      return _copy(p, tracks: list);
    });
  }

  List<Playlist> search(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return playlists.value.where((p) {
      if (p.title.toLowerCase().contains(q)) return true;
      return p.tracks.any((t) =>
          t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q));
    }).toList();
  }

  Playlist _copy(Playlist p, {String? title, List<Track>? tracks}) {
    final list = tracks ?? p.tracks;
    var cover = '';
    for (final t in list) {
      if (t.imageUrl.isNotEmpty) {
        cover = t.imageUrl;
        break;
      }
    }
    return Playlist(
      id: p.id,
      title: title ?? p.title,
      description: p.description,
      imageUrl: cover,
      ownerId: p.ownerId,
      createdAt: p.createdAt,
      tracks: list,
    );
  }

  Future<void> _update(String id, Playlist Function(Playlist) change) async {
    playlists.value =
        playlists.value.map((p) => p.id == id ? change(p) : p).toList();
    await _save();
  }

  Future<void> _save() async {
    if (!_started) return;
    try {
      final saved = await Vault.instance.writeText(
        _vaultName,
        json.encode(playlists.value.map((p) => p.toJson()).toList()),
      );
      if (!saved) debugPrint('playlist save failed: the secure store is not available');
    } catch (e) {
      debugPrint('playlist save failed: $e');
    }
  }
}
