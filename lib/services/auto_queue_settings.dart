import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track_model.dart';
import 'artist_credit.dart';

/// What the auto queue picks after a song.
enum AutoQueueMode {
  /// Songs like this one, the way YouTube Music suggests them (the default).
  similar,

  /// Only songs by one artist.
  sameArtist,
}

/// The artist the auto queue follows in [AutoQueueMode.sameArtist].
class ArtistFocus {
  /// Whose songs play.
  final String name;

  /// Who is credited on the song this was decided for. [ArtistCredit.none] when that song has no
  /// artist text: [name] is then what the user searched for.
  final ArtistCredit credit;

  /// False until YouTube Music has been asked about [name] (see [needsCheck]).
  final bool checked;

  const ArtistFocus(this.name, this.credit, {required this.checked});

  /// It is not sure yet that [name] is one artist: either the main credit of the song may be a
  /// single act ("Simon & Garfunkel", not "Simon" and "Garfunkel"), or the song has no artist text
  /// and [name] is the search text. YouTube Music is asked before any song is picked.
  bool get needsCheck => !checked;
}

/// The auto queue setting: similar songs (default) or the same artist only.
///
/// "Same artist" follows one artist, who is decided for the song that is playing when the auto
/// queue needs one:
///  1. the artist followed so far, while the song is credited to them;
///  2. else the artist the user searched for, when the song is credited to them;
///  3. else the main (first credited) artist of the song.
class AutoQueueSettings {
  AutoQueueSettings._();
  static final AutoQueueSettings instance = AutoQueueSettings._();

  static const String _modeKey = 'auto_queue_mode_v1';

  final ValueNotifier<AutoQueueMode> mode =
      ValueNotifier<AutoQueueMode>(AutoQueueMode.similar);

  /// The artist being followed. Null until the auto queue needs one, and while the song has no
  /// known artist.
  final ValueNotifier<ArtistFocus?> focus = ValueNotifier<ArtistFocus?>(null);

  /// A short hint for when "same artist" could not be done ("No songs by X found...").
  final ValueNotifier<String?> note = ValueNotifier<String?>(null);

  // What the user searched for (or the artist page they came from) to start this listening session
  String? _searched;
  // Main credits that YouTube Music knows as one artist ("coheedandcambria") and those it does
  // not ("drakefuture"): each is asked about once
  final Set<String> _acts = <String>{};
  final Set<String> _notActs = <String>{};

  /// Never throws: a setting that cannot be read just stays at its default.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_modeKey);
      mode.value = AutoQueueMode.values
          .firstWhere((m) => m.name == saved, orElse: () => AutoQueueMode.similar);
    } catch (e) {
      debugPrint('auto-queue: could not read the saved setting: $e');
    }
  }

  Future<void> setMode(AutoQueueMode m) async {
    if (mode.value == m) return;
    mode.value = m;
    focus.value = null; // decided again for the song that is playing
    note.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, m.name);
    } catch (e) {
      debugPrint('auto-queue: could not save the setting: $e');
    }
  }

  /// The user started a song. [searchedFor] is the search text (or artist page) it was picked
  /// from, if any. Whoever was followed before no longer counts.
  void begin(String? searchedFor) {
    final s = searchedFor?.trim();
    _searched = (s == null || s.isEmpty) ? null : s;
    endFocus();
  }

  void endFocus() {
    if (focus.value != null) focus.value = null;
    if (note.value != null) note.value = null;
  }

  void say(String? text) {
    if (note.value != text) note.value = text;
  }

  /// Decides which artist to follow for [song], the song the auto queue picks after.
  /// Does nothing unless the mode is "same artist". Cheap, and the same song gives the same answer.
  ArtistFocus? follow(Track song) {
    if (mode.value != AutoQueueMode.sameArtist) return null;
    final credit = ArtistCredit.of(song);
    final cur = focus.value;
    // still the artist followed so far (a song with no artist text does not change that)
    if (cur != null && (credit.isEmpty || credit.has(cur.name))) return cur;

    final searched = _searched;
    ArtistFocus? next;
    if (credit.isEmpty) {
      // no artist text on the song: the search may still name one, if YouTube Music knows it
      if (searched != null && searched.length <= 60) {
        next = ArtistFocus(searched, credit, checked: false);
      }
    } else {
      // the artist searched for, when this song is credited to them; else its main artist
      var name = (searched == null ? null : credit.named(searched)) ?? credit.main.first;
      var checked = true;
      final whole = credit.act;
      if (whole != null &&
          whole.length <= 80 &&
          credit.main.any((m) => ArtistCredit.norm(m) == ArtistCredit.norm(name))) {
        // "Drake & Future": two artists, or one act like "Coheed and Cambria"?
        final k = ArtistCredit.norm(whole);
        if (_acts.contains(k)) {
          name = whole;
        } else if (!_notActs.contains(k)) {
          checked = false;
        }
      }
      next = ArtistFocus(name, credit, checked: checked);
    }
    if (next == null) {
      endFocus();
      return null;
    }
    focus.value = next;
    note.value = null;
    return next;
  }

  /// YouTube Music knows [name] as an artist: that is who is followed. For a song with no artist
  /// text [name] is the artist's name as YouTube Music writes it; otherwise it is the whole main
  /// credit ("Coheed and Cambria").
  void confirm(ArtistFocus f, String name) {
    if (!identical(focus.value, f)) return; // moved on meanwhile
    final whole = f.credit.act;
    if (whole != null && ArtistCredit.norm(whole) == ArtistCredit.norm(name)) {
      _acts.add(ArtistCredit.norm(whole));
    }
    focus.value = ArtistFocus(name, f.credit, checked: true);
  }

  /// YouTube Music does not know it. A main credit that is not one act ("Drake & Future") keeps
  /// the artist that was picked. A search text that is not an artist leaves the song without
  /// an artist.
  void deny(ArtistFocus f) {
    if (!identical(focus.value, f)) return;
    if (f.credit.isEmpty) {
      focus.value = null;
      return;
    }
    final whole = f.credit.act;
    if (whole != null) _notActs.add(ArtistCredit.norm(whole));
    focus.value = ArtistFocus(f.name, f.credit, checked: true);
  }
}
