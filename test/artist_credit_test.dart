import 'package:flutter_test/flutter_test.dart';
import 'package:xtify_app/services/artist_credit.dart';

// Who is credited on a song: "X ft. Y", "X & Y", "Tyler, The Creator" ...
// Run with: flutter test test/artist_credit_test.dart
void main() {
  void check(
    String artist,
    List<String> main, {
    List<String> guests = const <String>[],
    String? act,
    String title = '',
  }) {
    final c = ArtistCredit.parse(artist, title: title);
    expect(c.main, main, reason: 'main artists of "$artist" / "$title"');
    expect(c.guests, guests, reason: 'featured artists of "$artist" / "$title"');
    expect(c.act, act, reason: 'group name of "$artist" / "$title"');
  }

  test('splits the artist text and the title into main and featured artists', () {
    check('Drake', ['Drake']);
    check('Maroon 5 feat. Kendrick Lamar', ['Maroon 5'], guests: ['Kendrick Lamar']);
    check('Dua Lipa (feat. DaBaby)', ['Dua Lipa'], guests: ['DaBaby']);
    check('Drake & Future', ['Drake', 'Future'], act: 'Drake & Future');
    check('Simon & Garfunkel', ['Simon & Garfunkel']);
    check('Tyler, the Creator', ['Tyler, the Creator']);
    check('Kool & the Gang', ['Kool & the Gang']);
    check('Sammy Davis, Jr.', ['Sammy Davis, Jr.']);
    check('AC/DC', ['AC/DC']);
    check('FT Island', ['FT Island']);
    check('Lil Nas X', ['Lil Nas X']);
    check('Lil Nas X & Jack Harlow', ['Lil Nas X', 'Jack Harlow'], act: 'Lil Nas X & Jack Harlow');
    check('Calvin Harris, Dua Lipa', ['Calvin Harris', 'Dua Lipa'], act: 'Calvin Harris, Dua Lipa');
    check('Earth, Wind & Fire', ['Earth, Wind & Fire']);
    check('Charli XCX x Troye Sivan', ['Charli XCX', 'Troye Sivan'], act: 'Charli XCX x Troye Sivan');
    check('A\$AP Rocky', ['A\$AP Rocky']);
    check('Florence + the Machine', ['Florence + the Machine']);
    check('Rihanna & The Weeknd', ['Rihanna', 'The Weeknd'], act: 'Rihanna & The Weeknd');
    check('Ed Sheeran feat. Justin Bieber & Zayn', ['Ed Sheeran'], guests: ['Justin Bieber', 'Zayn']);
    check('Post Malone', ['Post Malone'], guests: ['Swae Lee'], title: 'Sunflower (feat. Swae Lee)');
    check('Post Malone', ['Post Malone'], guests: ['Swae Lee'], title: 'Sunflower (Spider-Man) [ft. Swae Lee]');
    check('', [], title: 'Song (feat. X)');
    check('Artist - Topic', ['Artist']);
    check('Various Artists', []);
    check('Ado', ['Ado']);
    check('Kendrick Lamar, SZA', ['Kendrick Lamar', 'SZA'], act: 'Kendrick Lamar, SZA');
    check('Hall and Oates', ['Hall and Oates']);
    check('Tom Petty and the Heartbreakers', ['Tom Petty and the Heartbreakers']);
    check('Marina and the Diamonds', ['Marina and the Diamonds']);
    check('Of Monsters and Men', ['Of Monsters and Men']);
    check('Panic! at the Disco', ['Panic! at the Disco']);
    check('Guns N\' Roses', ['Guns N\' Roses']);
    check('Jay-Z & Kanye West', ['Jay-Z', 'Kanye West'], act: 'Jay-Z & Kanye West');
    check('Juice WRLD x Marshmello', ['Juice WRLD', 'Marshmello'], act: 'Juice WRLD x Marshmello');
    check('Blinding Lights', ['Blinding Lights']);
    check('The Weeknd', ['The Weeknd'], title: 'Blinding Lights (Official Audio)');
    check('The Weeknd', ['The Weeknd'], guests: ['A'], title: 'Song ft. A (Official Video)');
    check('Soft Cell', ['Soft Cell'], title: 'Feature Film');
    check('Jamie xx', ['Jamie xx']);
    check('The xx', ['The xx']);
    check('Kendrick Lamar x SZA', ['Kendrick Lamar', 'SZA'], act: 'Kendrick Lamar x SZA');
    check('Anderson .Paak & Bruno Mars', ['Anderson .Paak', 'Bruno Mars'], act: 'Anderson .Paak & Bruno Mars');
    check('Dan + Shay', ['Dan + Shay']);
    check('Mumford & Sons', ['Mumford & Sons']);
    check('Drake feat. Drake', ['Drake']);
    check('Drake & Future feat. Young Thug', ['Drake', 'Future'], guests: ['Young Thug'], act: 'Drake & Future');
    check('Bad Bunny ft Rauw Alejandro', ['Bad Bunny'], guests: ['Rauw Alejandro']);
    check('Bad Bunny FEATURING Rauw Alejandro', ['Bad Bunny'], guests: ['Rauw Alejandro']);
    check('Feature Creep', ['Feature Creep']);
    check('【Ado】', ['【Ado】']);
    check('YOASOBI', ['YOASOBI']);
    check('藤井 風', ['藤井 風']);
    check('Ado ft. 初音ミク', ['Ado'], guests: ['初音ミク']);
    check('Lil Nas X x Jack Harlow', ['Lil Nas X', 'Jack Harlow'], act: 'Lil Nas X x Jack Harlow');
    check('Malcolm X', ['Malcolm X']);
    check('DRAKE AND FUTURE', ['DRAKE', 'FUTURE'], act: 'DRAKE AND FUTURE');
    check('Drake  &   Future', ['Drake', 'Future'], act: 'Drake & Future');
    check('Drake; Future', ['Drake', 'Future'], act: 'Drake; Future');
    check('Eminem vs. Dr. Dre', ['Eminem', 'Dr. Dre'], act: 'Eminem vs. Dr. Dre');
    check('Peter, Paul and Mary', ['Peter, Paul and Mary']);
    check('Tyler, The Creator', ['Tyler, The Creator']);
    check('Tyler, The Creator & Kali Uchis', ['Tyler, The Creator', 'Kali Uchis'], act: 'Tyler, The Creator & Kali Uchis');
    check('Hootie & The Blowfish', ['Hootie & The Blowfish']);
    check('Brooks & Dunn feat. Reba McEntire', ['Brooks & Dunn'], guests: ['Reba McEntire']);
    check('Drake & Simon & Garfunkel', ['Drake', 'Simon & Garfunkel'], act: 'Drake & Simon & Garfunkel');
    check('Calvin Harris & Hall & Oates', ['Calvin Harris', 'Hall & Oates'], act: 'Calvin Harris & Hall & Oates');
    check('Hall & Oatesy', ['Hall', 'Oatesy'], act: 'Hall & Oatesy');
    check('Matt & Kimberly', ['Matt', 'Kimberly'], act: 'Matt & Kimberly');
    check('Mumford & Sons feat. Baaba Maal', ['Mumford & Sons'], guests: ['Baaba Maal']);
  });

  test('no artist text means nobody is credited', () {
    expect(ArtistCredit.parse('').isEmpty, isTrue);
    expect(ArtistCredit.parse('Various Artists').isEmpty, isTrue);
    expect(ArtistCredit.parse('', title: 'Song (feat. X)').isEmpty, isTrue);
  });

  test('named() finds the credited artist a search text is about', () {
    void check(String artist, String searched, String? want, {String title = ''}) {
      expect(ArtistCredit.parse(artist, title: title).named(searched), want,
          reason: '"$searched" in "$artist" / "$title"');
    }

    check('Drake ft. Future', 'drake', 'Drake');
    check('Drake ft. Future', 'Future', 'Future');
    check('Future ft. Drake', 'drake', 'Drake');
    check('Drake & Future', 'future', 'Future');
    check('Drake & Future', 'drake future', 'Drake');
    check('Drake', 'travis scott', 'Travis Scott', title: 'Sicko Mode (feat. Travis Scott)');
    check('Kendrick Lamar', 'kendrick', 'Kendrick Lamar');
    check('Kendrick Lamar', 'lamar', 'Kendrick Lamar');
    check('The Weeknd', 'weeknd', 'The Weeknd');
    check('The Weeknd', 'the weeknd', 'The Weeknd');
    check('Weeknd', 'The Weeknd', 'Weeknd');
    check('Drake', 'drake songs', 'Drake');
    check('Drake', 'DRAKE', 'Drake');
    check('Drake', 'hotline bling', null);
    check('Drake', 'dra', null);
    check('Ed Sheeran', 'ed', null);
    check('Ed Sheeran', 'sheeran', 'Ed Sheeran');
    check('BTS', 'bts dynamite', 'BTS');
    check('IU', 'iu', 'IU');
    check('IU', 'iu songs', null);
    check('Tyler, The Creator', 'tyler the creator', 'Tyler, The Creator');
    check('Simon & Garfunkel', 'simon and garfunkel', 'Simon & Garfunkel');
    check('Lil Nas X & Jack Harlow', 'jack harlow', 'Jack Harlow');
    check('Lil Nas X & Jack Harlow', 'lil nas x', 'Lil Nas X');
    check('あいみょん', 'あいみょん', 'あいみょん');
    check('', 'drake', null, title: 'Song');
    check('Drake', '', null);
    check('Drake', '   ', null);
    check('Drake', '!!!', null);
    check('Beyoncé', 'beyoncé', 'Beyoncé');
    check('Maroon 5', 'maroon', 'Maroon 5');
    check('Maroon 5', 'maroon 5', 'Maroon 5');
    check('Maroon 5 feat. Kendrick Lamar', 'kendrick lamar', 'Kendrick Lamar');
  });

  test('has() ignores case and punctuation, and knows a group as a whole', () {
    final tyler = ArtistCredit.parse('Tyler, The Creator & Kali Uchis');
    expect(tyler.has('tyler the creator'), isTrue);
    expect(tyler.has('Kali Uchis'), isTrue);
    expect(tyler.has('Tyler'), isFalse);
    final duo = ArtistCredit.parse('Blue Moon & Sun');
    expect(duo.has('Blue Moon & Sun'), isTrue); // the whole credit, as one group
    expect(duo.has('sun'), isTrue);
    expect(duo.has('Moon'), isFalse);
  });
}
