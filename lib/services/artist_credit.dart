import '../models/track_model.dart';

/// Who a song is by.
///
/// The artist text can name several artists ("Drake & Future", "Maroon 5 feat. Kendrick Lamar")
/// and so can the title ("Song (feat. Future)"). The text is cut at the usual joining words.
/// That is a best guess: "Simon & Garfunkel" reads like two artists, so [act] keeps the whole
/// main credit as one possible name, and the auto queue asks YouTube Music whether such an
/// artist exists before it follows either name.
class ArtistCredit {
  /// The artists the song is by, the main one first.
  final List<String> main;

  /// Artists featured on the song ("feat. ...", also taken from the title).
  final List<String> guests;

  /// The main credit as it was written, when it names more than one artist
  /// ("Simon & Garfunkel", "Earth, Wind & Fire"): it may be one group. Null otherwise.
  final String? act;

  const ArtistCredit._(this.main, this.guests, this.act);

  /// Nobody is credited (the song has no artist text).
  static const ArtistCredit none = ArtistCredit._(<String>[], <String>[], null);

  /// Everybody credited, the main artist first.
  List<String> get names => [...main, ...guests];

  /// No artist is known for the song.
  bool get isEmpty => main.isEmpty;

  /// [name] is one of the credited artists (or the main credit as a whole).
  bool has(String name) {
    final n = norm(name);
    if (n.isEmpty) return false;
    final whole = act;
    if (whole != null && norm(whole) == n) return true;
    return names.any((x) => norm(x) == n);
  }

  /// The credited artist that [query] is about, as the song writes the name, or null.
  /// [query] is what the user searched for. Case, punctuation and a leading "the" do not matter.
  /// A part of the name is enough ("kendrick" finds "Kendrick Lamar"), and so is a longer text
  /// that has the whole name in it ("drake songs"). A whole-name match wins, then the artist
  /// credited first.
  String? named(String query) {
    final q = _words(query);
    if (q.isEmpty) return null;
    final all = names;
    for (final n in all) {
      if (_words(n).join(' ') == q.join(' ')) return n;
    }
    for (final n in all) {
      final w = _words(n);
      if (_within(q, w) || _within(w, q)) return n;
    }
    return null;
  }

  static ArtistCredit of(Track t) => parse(t.artist, title: t.title);

  static ArtistCredit parse(String artist, {String title = ''}) {
    var text = artist.replaceAll(RegExp(r'\s+'), ' ').trim();
    text = text.replaceAll(RegExp(r'\s*-\s*topic$', caseSensitive: false), '').trim();
    if (text.isEmpty) return none;

    // "Main feat. Guest": the feature marker cuts the credit in two
    var mainText = text;
    var guestText = '';
    final f = _feature.firstMatch(text);
    if (f != null && f.start > 0) {
      mainText = text.substring(0, f.start);
      guestText = text.substring(f.end);
      if (RegExp(r'[(\[]').hasMatch(f.group(0)!)) {
        guestText = guestText.replaceAll(RegExp(r'\s*[)\]].*$'), ''); // "Main (feat. Guest)"
      }
    }
    final main = _names(mainText);
    if (main.isEmpty) return none;
    final seen = main.map(norm).toSet();
    final guests = <String>[];
    for (final g in [..._names(guestText), ..._titleGuests(title)]) {
      if (seen.add(norm(g))) guests.add(g);
    }
    return ArtistCredit._(main, guests, main.length > 1 ? _clean(mainText) : null);
  }

  /// Letters and digits only, lower case: "Tyler, The Creator" and "tyler the creator" match.
  static String norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static final RegExp _wordRe = RegExp(r'[\p{L}\p{M}\p{N}]+', unicode: true);

  /// The words of a name, lower case: "The Weeknd" and "weeknd" both give [weeknd].
  static List<String> _words(String s) {
    final w = [for (final m in _wordRe.allMatches(s.toLowerCase())) m.group(0)!];
    if (w.length > 1 && w.first == 'the') w.removeAt(0);
    return w;
  }

  /// Every word of [a] is a word of [b], and [a] is not just a letter or two.
  static bool _within(List<String> a, List<String> b) =>
      a.join().length >= 3 && a.every(b.contains);

  // "Main feat. Guest", "Main (ft. Guest)", "Main [featuring Guest]". Needs something in front,
  // so a band called "FT Island" is left alone.
  static final RegExp _feature =
      RegExp(r'[\s(\[]+(?:feat(?:uring)?|ft)\b\.?\s+', caseSensitive: false);

  // "Song (feat. A & B)", "Song [ft. A]", "Song ft. A" in a title
  static final RegExp _titleFeature = RegExp(
    r'[(\[]\s*(?:feat(?:uring)?|ft)\b\.?\s+([^)\]]+)[)\]]|\s(?:feat(?:uring)?|ft)\b\.?\s+(.+)$',
    caseSensitive: false,
  );

  // Joins two artists: "A, B", "A & B", "A + B", "A / B", "A x B", "A and B", "A vs. B".
  // Only a lower case x joins ("Lil Nas X & Jack Harlow" has a name that ends in X).
  static final RegExp _join =
      RegExp(r'\s*[,;]\s*|\s+(?:&|\+|/|x|×|[aA][nN][dD]|[vV][sS]\.?)\s+');

  // "Sammy Davis, Jr." is one name
  static final RegExp _suffix = RegExp(r'^(?:jr|sr)\b\.?', caseSensitive: false);

  static final RegExp _edge =
      RegExp(r'^[\s"“”‘’]+|[\s"“”‘’]+$');

  // Well-known acts whose name contains a joining word: one artist, not two. Anything else that
  // looks like two artists is checked with YouTube Music (see [act]).
  static const List<String> _oneName = [
    'Tyler, The Creator',
    'Earth, Wind & Fire',
    'Crosby, Stills, Nash & Young',
    'Crosby, Stills & Nash',
    'Blood, Sweat & Tears',
    'Emerson, Lake & Palmer',
    'Peter, Paul and Mary',
    'Simon & Garfunkel',
    'Daryl Hall & John Oates',
    'Hall & Oates',
    'Hall and Oates',
    'Brooks & Dunn',
    'Mumford & Sons',
    'Years & Years',
    'Dan + Shay',
    'Florence + The Machine',
    'Kool & The Gang',
    'Bob Marley & The Wailers',
    'Hootie & The Blowfish',
    'Tom Petty and The Heartbreakers',
    'Gladys Knight & The Pips',
    'Katrina & The Waves',
    'Echo & The Bunnymen',
    'Marina and The Diamonds',
    'Of Monsters and Men',
    'Belle and Sebastian',
    'Tegan and Sara',
    'Peter Bjorn and John',
    'Angus & Julia Stone',
    'Chase & Status',
    'Matt & Kim',
    'Sam & Dave',
    'Ike & Tina Turner',
    'Sly & Robbie',
    'Big & Rich',
    'Nico & Vinz',
  ];

  static final RegExp _known = RegExp(
    '(?<![\\p{L}\\p{N}])(?:${_oneName.map(RegExp.escape).join('|')})(?![\\p{L}\\p{N}])',
    caseSensitive: false,
    unicode: true,
  );

  // marks where a known act was taken out of the text (see _names)
  static final RegExp _shield = RegExp('\u0001(\\d+)\u0001');

  static const Set<String> _notNames = {
    'various artists', 'various', 'unknown artist', 'unknown', 'va', 'n/a',
    'official', 'video', 'audio', 'lyrics', 'lyric', 'music', 'mv', 'hd', '4k',
  };

  static String _clean(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(_edge, '').trim();

  static List<String> _split(String text) {
    final parts = <String>[];
    var start = 0;
    for (final m in _join.allMatches(text)) {
      final rest = text.substring(m.end);
      // "Tyler, the Creator", "Kool & the Gang" are one name; so is "Sammy Davis, Jr."
      if (rest.startsWith('the ') || _suffix.hasMatch(rest)) continue;
      parts.add(text.substring(start, m.start));
      start = m.end;
    }
    parts.add(text.substring(start));
    return parts;
  }

  static List<String> _names(String text) {
    // a known act ("Earth, Wind & Fire") is set aside so that it is not cut up
    final acts = <String>[];
    final shielded = text.replaceAllMapped(_known, (m) {
      acts.add(m.group(0)!);
      return '\u0001${acts.length - 1}\u0001';
    });
    final out = <String>[];
    final seen = <String>{};
    for (final raw in _split(shielded)) {
      final n = _clean(raw.replaceAllMapped(_shield, (m) => acts[int.parse(m.group(1)!)]));
      if (n.isEmpty || n.length > 60 || _notNames.contains(n.toLowerCase())) continue;
      if (seen.add(norm(n))) out.add(n);
    }
    return out;
  }

  static List<String> _titleGuests(String title) {
    if (title.isEmpty) return const <String>[];
    final m = _titleFeature.firstMatch(title);
    if (m == null) return const <String>[];
    var g = m.group(1) ?? m.group(2) ?? '';
    g = g.replaceAll(RegExp(r'\s*[(\[].*$'), ''); // "feat. A (Official Video)"
    return _names(g);
  }
}
