// ignore_for_file: avoid_print

import 'package:lyric_music/music_sdk/wy_catalog.dart';
import 'package:lyric_music/music_sdk/wy_search.dart';

/// Checks the batch-2 catalog calls (search tabs, artist, album) end to end.
/// Run: dart run tool/probe_batch2.dart
Future<void> main() async {
  final kw = '陈奕迅';
  final artists = await WySearch().searchArtists(kw);
  print('artists total=${artists.total} first=${artists.list.first.name}/${artists.list.first.id} '
      'alias=${artists.list.first.alias} music=${artists.list.first.musicSize}');

  final albums = await WySearch().searchAlbums(kw);
  print('albums total=${albums.total} first=${albums.list.first.name} '
      'by ${albums.list.first.artist} (${albums.list.first.publishYear}) id=${albums.list.first.id} '
      'artistId=${albums.list.first.artistId}');

  final sheets = await WySearch().searchSheets(kw);
  print('sheets total=${sheets.total} first=${sheets.list.first.name} '
      'img=${sheets.list.first.img != null}');

  final artistId = artists.list.first.id;
  final detail = await WyCatalog.artist(artistId);
  print('artist ${detail.artist.name}: desc="${detail.artist.desc}" songs=${detail.songs.length} '
      'first=${detail.songs.first.name} pic=${detail.songs.first.pic != null}');

  final discography = await WyCatalog.artistAlbums(artistId);
  print('artist albums=${discography.length} first=${discography.first.name} '
      '${discography.first.publishYear}');

  final albumId = discography.isNotEmpty ? discography.first.id : albums.list.first.id;
  final album = await WyCatalog.album(albumId);
  print('album ${album.album.name} by ${album.album.artist} tracks=${album.songs.length} '
      'first=${album.songs.take(3).map((s) => s.name).join(' | ')}');
}
