import 'package:xtify_app/models/track_model.dart';

class Playlist {
  final String id;
  final String title;
  final String description;
  final String imageUrl;
  final String ownerId;
  final DateTime createdAt;
  final List<Track> tracks;

  Playlist({
    required this.id,
    required this.title,
    this.description = '',
    required this.imageUrl,
    required this.ownerId,
    required this.createdAt,
    required this.tracks,
  });

  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      imageUrl: json['imageUrl'] ?? '',
      ownerId: json['ownerId'] ?? '',
      createdAt: DateTime.parse(json['createdAt'] ?? DateTime.now().toIso8601String()),
      tracks: (json['tracks'] as List? ?? [])
          .map((track) => Track.fromJson(track))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'imageUrl': imageUrl,
      'ownerId': ownerId,
      'createdAt': createdAt.toIso8601String(),
      'tracks': tracks.map((track) => track.toJson()).toList(),
    };
  }
}