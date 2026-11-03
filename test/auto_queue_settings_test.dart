import 'package:flutter_test/flutter_test.dart';
import 'package:xtify_app/models/track_model.dart';
import 'package:xtify_app/services/auto_queue_settings.dart';

// Which artist the "same artist" auto queue follows.
// Run with: flutter test test/auto_queue_settings_test.dart
Track song(String artist, String title) => Track(
      id: 'abcdefghijk',
      title: title,
      artist: artist,
      album: '',
      duration: '3:30',
      imageUrl: '',
      previewUrl: '',
    );

void main() {
  final s = AutoQueueSettings.instance;

  setUp(() {
    s.mode.value = AutoQueueMode.sameArtist;
    s.begin(null); // a song picked without a search
  });

  test('similar songs follow nobody', () {
    s.mode.value = AutoQueueMode.similar;
    expect(s.follow(song('Drake', 'God\'s Plan')), isNull);
  });

  test('the artist searched for, when the song is credited to them', () {
    s.begin('future');
    expect(s.follow(song('Drake ft. Future', 'Way 2 Sexy'))?.name, 'Future');
    s.begin('drake');
    expect(s.follow(song('Future ft. Drake', 'Life Is Good'))?.name, 'Drake');
    s.begin('kendrick');
    expect(s.follow(song('Maroon 5 feat. Kendrick Lamar', 'Don\'t Wanna Know'))?.name,
        'Kendrick Lamar');
  });

  test('a search text that is no artist of the song gives the main artist', () {
    s.begin('way 2 sexy');
    expect(s.follow(song('Drake ft. Future', 'Way 2 Sexy'))?.name, 'Drake');
    s.begin(null);
    expect(s.follow(song('Drake ft. Future', 'Way 2 Sexy'))?.name, 'Drake');
  });

  test('searched for an artist, then the queue drifted to another one: the playing song\'s main artist', () {
    s.begin('drake');
    expect(s.follow(song('Future', 'Mask Off'))?.name, 'Future');
  });

  test('stays with the artist while songs are credited to them, else follows the new song', () {
    final first = s.follow(song('Drake', 'God\'s Plan'));
    expect(first?.name, 'Drake');
    expect(s.follow(song('Future ft. Drake', 'Life Is Good')), same(first));
    expect(s.follow(song('Adele', 'Hello'))?.name, 'Adele');
  });

  test('a song without artist text follows the search text once YouTube Music knows it', () {
    s.begin('drake');
    final f = s.follow(song('', 'God\'s Plan'))!;
    expect(f.name, 'drake');
    expect(f.needsCheck, isTrue);
    s.confirm(f, 'Drake'); // the name as YouTube Music writes it
    expect(s.focus.value?.name, 'Drake');
    expect(s.focus.value?.needsCheck, isFalse);
  });

  test('a search text that is no artist leaves a song without artist text unfollowed', () {
    s.begin('god\'s plan');
    final f = s.follow(song('', 'God\'s Plan'))!;
    s.deny(f);
    expect(s.focus.value, isNull);
    s.begin(null);
    expect(s.follow(song('', 'God\'s Plan')), isNull);
    s.begin('x' * 61); // far too long to be an artist
    expect(s.follow(song('', 'God\'s Plan')), isNull);
  });

  test('two artists: the first one, and YouTube Music is asked once whether they are one act', () {
    final f = s.follow(song('Blue Moon & Sun', 'Orbit'))!;
    expect(f.name, 'Blue Moon');
    expect(f.needsCheck, isTrue);
    s.deny(f); // no such act
    expect(s.focus.value?.name, 'Blue Moon');
    expect(s.focus.value?.needsCheck, isFalse);
    s.begin(null);
    expect(s.follow(song('Blue Moon & Sun', 'Again'))?.needsCheck, isFalse); // not asked again
  });

  test('an act that YouTube Music knows is followed as a whole', () {
    final f = s.follow(song('Coheed and Cambria', 'Welcome Home'))!;
    expect(f.name, 'Coheed');
    expect(f.needsCheck, isTrue);
    s.confirm(f, 'Coheed and Cambria');
    expect(s.focus.value?.name, 'Coheed and Cambria');
    s.begin(null);
    final again = s.follow(song('Coheed and Cambria', 'Ten Speed'))!;
    expect(again.name, 'Coheed and Cambria');
    expect(again.needsCheck, isFalse);
  });
}
