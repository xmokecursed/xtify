import 'package:xtify_app/models/track_model.dart';

class Album {
  final String id;
  final String title;
  final String artist;
  final String imageUrl;
  final String releaseDate;
  final int totalTracks;
  final List<Track> tracks;

  Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.imageUrl,
    required this.releaseDate,
    required this.totalTracks,
    required this.tracks,
  });

  factory Album.fromJson(Map<String, dynamic> json) {
    return Album(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      artist: json['artist'] ?? '',
      imageUrl: json['imageUrl'] ?? '',
      releaseDate: json['releaseDate'] ?? '',
      totalTracks: json['totalTracks'] ?? 0,
      tracks: (json['tracks'] as List? ?? [])
          .map((track) => Track.fromJson(track))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'artist': artist,
      'imageUrl': imageUrl,
      'releaseDate': releaseDate,
      'totalTracks': totalTracks,
      'tracks': tracks.map((track) => track.toJson()).toList(),
    };
  }
}