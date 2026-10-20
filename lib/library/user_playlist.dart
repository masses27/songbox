import '../models/song.dart';

/// A playlist the user builds inside this app (自建歌单), as opposed to the
/// NetEase playlists the catalog serves up.
class UserPlaylist {
  final String id;
  String name;
  final List<Song> songs;
  final int createdAt;

  UserPlaylist({
    required this.id,
    required this.name,
    List<Song>? songs,
    int? createdAt,
  })  : songs = songs ?? [],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  bool has(Song s) => songs.any((e) => e.source == s.source && e.songmid == s.songmid);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  factory UserPlaylist.fromJson(Map<String, dynamic> j) => UserPlaylist(
        id: '${j['id']}',
        name: '${j['name'] ?? '未命名歌单'}',
        createdAt: (j['createdAt'] as num?)?.toInt(),
        songs: ((j['songs'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}
