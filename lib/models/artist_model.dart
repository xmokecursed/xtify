class Artist {
  final String id;
  final String name;
  final String imageUrl;
  final int followers;
  final List<String> genres;
  final int popularity;

  Artist({
    required this.id,
    required this.name,
    required this.imageUrl,
    required this.followers,
    required this.genres,
    required this.popularity,
  });

  factory Artist.fromJson(Map<String, dynamic> json) {
    return Artist(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      imageUrl: json['imageUrl'] ?? '',
      followers: json['followers'] ?? 0,
      genres: List<String>.from(json['genres'] ?? []),
      popularity: json['popularity'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'imageUrl': imageUrl,
      'followers': followers,
      'genres': genres,
      'popularity': popularity,
    };
  }
}