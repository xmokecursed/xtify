import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/track_model.dart';
import '../models/album_model.dart';

class ApiService {
  static const String _baseUrl = 'https://xtify-backend.onrender.com';

  // Search for tracks (using YouTube search endpoint)
  static Future<List<Track>> searchTracks(String query, {int limit = 25}) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/search').replace(queryParameters: {
        'q': query,
        'limit': '$limit',
      }),
    ).timeout(const Duration(seconds: 60));

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      final List<Track> allTracks = data.map((json) => Track.fromJson(json)).toList();
      // Filter for playable items: id must be 11-char YouTube ID
      final List<Track> playableTracks = allTracks.where((track) => track.isPlayable).toList();
      // Drop items with null duration or duration above 900 s (15 minutes)
      final List<Track> durationFiltered = playableTracks.where((track) {
        final durationSeconds = _parseDurationToSeconds(track.duration);
        return durationSeconds != null && durationSeconds > 0 && durationSeconds <= 900;
      }).toList();
      // Drop duplicate ids, keep first occurrence
      final Set<String> seenIds = <String>{};
      final List<Track> uniqueTracks = <Track>[];
      for (final track in durationFiltered) {
        if (!seenIds.contains(track.id)) {
          seenIds.add(track.id);
          uniqueTracks.add(track);
        }
      }
      return uniqueTracks;
    } else {
      throw Exception('Search failed (HTTP ${response.statusCode})');
    }
  }

  /// Helper to convert duration string (m:ss or ss) to seconds.
  static int? _parseDurationToSeconds(String duration) {
    if (duration.isEmpty) return null;
    final parts = duration.split(':');
    if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]);
      final seconds = int.tryParse(parts[1]);
      if (minutes != null && seconds != null) {
        return minutes * 60 + seconds;
      }
    } else if (parts.length == 1) {
      final seconds = int.tryParse(parts[0]);
      return seconds;
    }
    return null;
  }

  // Get album information
  static Future<Album?> getAlbumInfo(String artist, String album) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/album/$artist/$album'),
    );

    if (response.statusCode == 200) {
      final Map<String, dynamic> data = json.decode(response.body);
      return Album.fromJson(data);
    } else {
      return null;
    }
  }

  // Similar artists: the backend returns a bare array [{name, url, image}]
  static Future<List<String>> getSimilarArtistNames(String artistName) async {
    final uri = Uri.parse(_baseUrl).replace(pathSegments: ['similar', artistName]);
    final response = await http.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('Failed to get similar artists (HTTP ${response.statusCode})');
    }
    final data = json.decode(response.body) as List<dynamic>;
    return data
        .map((e) => ((e as Map<String, dynamic>)['name'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();
  }

  // Artist top tracks (Last.fm, no video ids): [{name, artist, url, duration}]
  static Future<List<Track>> getArtistTopTracks(String artistName) async {
    final uri = Uri.parse(_baseUrl).replace(pathSegments: ['radio', artistName]);
    final response = await http.get(uri).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw Exception('Failed to get artist top tracks (HTTP ${response.statusCode})');
    }
    final data = json.decode(response.body) as List<dynamic>;
    return data.map((e) => Track.fromJson(e as Map<String, dynamic>)).toList();
  }

  // General search (youTube search from original backend)
  static Future<List<Track>> searchYouTube(String query) async {
    final response = await http.get(
      Uri.parse('$_baseUrl/search').replace(queryParameters: {
        'q': query,
      }),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = json.decode(response.body);
      return data.map((json) => Track.fromJson(json)).toList();
    } else {
      throw Exception('Failed to search YouTube');
    }
  }

  /// Last.fm track.getSimilar through the backend.
  static Future<List<SimilarTrack>> getSimilarTracks(
      String artist, String title, {int limit = 30}) async {
    final uri = Uri.parse(_baseUrl).replace(
      pathSegments: ['similar-tracks', artist, title],
      queryParameters: {'limit': '$limit'},
    );
    final r = await http.get(uri).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('Similar tracks failed (HTTP ${r.statusCode})');
    }
    final data = json.decode(r.body) as List<dynamic>;
    return data
        .map((e) {
          final m = e as Map<String, dynamic>;
          return SimilarTrack(
            name: (m['name'] ?? '').toString(),
            artist: (m['artist'] ?? '').toString(),
          );
        })
        .where((t) => t.name.isNotEmpty && t.artist.isNotEmpty)
        .toList();
  }

  /// Last.fm track search by name: [{name, artist}] (no video ids).
  static Future<List<SimilarTrack>> searchLastFmTracks(String query, {int limit = 3}) async {
    final uri = Uri.parse(_baseUrl).replace(
      pathSegments: ['track', 'search'],
      queryParameters: {'q': query, 'limit': '$limit'},
    );
    final r = await http.get(uri).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('Track search failed (HTTP ${r.statusCode})');
    }
    final data = json.decode(r.body) as List<dynamic>;
    return data
        .map((e) {
          final m = e as Map<String, dynamic>;
          return SimilarTrack(
            name: (m['name'] ?? '').toString(),
            artist: (m['artist'] ?? '').toString(),
          );
        })
        .where((t) => t.name.isNotEmpty && t.artist.isNotEmpty)
        .toList();
  }

  /// YouTube's own "what plays next" Mix for a video, from the backend's yt-dlp.
  static Future<List<Track>> getRelated(String videoId) async {
    final r = await http
        .get(Uri.parse('$_baseUrl/related/$videoId'))
        .timeout(const Duration(seconds: 45));
    if (r.statusCode != 200) {
      throw Exception('Related failed (HTTP ${r.statusCode})');
    }
    return (json.decode(r.body) as List<dynamic>)
        .map((e) => Track.fromJson(e as Map<String, dynamic>))
        .where((t) => t.isPlayable)
        .toList();
  }

  /// Similar songs from YouTube Music (its radio, else a song search), via the backend.
  static Future<List<Track>> getSimilarYtm(String videoId, {String query = '', String artist = ''}) async {
    final uri = Uri.parse(_baseUrl).replace(
      pathSegments: ['ytm', 'similar', videoId],
      queryParameters: {
        if (query.isNotEmpty) 'q': query,
        if (artist.isNotEmpty) 'artist': artist,
      },
    );
    final r = await http.get(uri).timeout(const Duration(seconds: 45));
    if (r.statusCode != 200) {
      throw Exception('YouTube Music similar failed (HTTP ${r.statusCode})');
    }
    return (json.decode(r.body) as List<dynamic>)
        .map((e) => Track.fromJson(e as Map<String, dynamic>))
        .where((t) => t.isPlayable)
        .toList();
  }

  /// Global Last.fm chart through the backend: [{name, artist}] (no video ids).
  static Future<List<SimilarTrack>> getTrending({int limit = 24, String? country}) async {
    final query = <String, String>{
      'limit': '$limit',
      if (country != null && country.isNotEmpty) 'country': country,
    };
    final r = await http
        .get(Uri.parse('$_baseUrl/trending').replace(queryParameters: query))
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('Trending failed (HTTP ${r.statusCode})');
    }
    final data = json.decode(r.body) as List<dynamic>;
    return data
        .map((e) {
          final m = e as Map<String, dynamic>;
          return SimilarTrack(
            name: (m['name'] ?? '').toString(),
            artist: (m['artist'] ?? '').toString(),
          );
        })
        .where((t) => t.name.isNotEmpty && t.artist.isNotEmpty)
        .toList();
  }
}

class SimilarTrack {
  final String name;
  final String artist;
  const SimilarTrack({required this.name, required this.artist});
}
