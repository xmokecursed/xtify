import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track_model.dart';
import 'artist_credit.dart';

enum AutoQueueMode {
  similar,

  sameArtist,
}

class ArtistFocus {
  final String name;

  final ArtistCredit credit;

  final bool checked;

  const ArtistFocus(this.name, this.credit, {required this.checked});

  bool get needsCheck => !checked;
}

class AutoQueueSettings {
  AutoQueueSettings._();
  static final AutoQueueSettings instance = AutoQueueSettings._();

  static const String _modeKey = 'auto_queue_mode_v1';

  final ValueNotifier<AutoQueueMode> mode =
      ValueNotifier<AutoQueueMode>(AutoQueueMode.similar);

  final ValueNotifier<ArtistFocus?> focus = ValueNotifier<ArtistFocus?>(null);

  final ValueNotifier<String?> note = ValueNotifier<String?>(null);

  String? _searched;
  final Set<String> _acts = <String>{};
  final Set<String> _notActs = <String>{};

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
    focus.value = null;
    note.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modeKey, m.name);
    } catch (e) {
      debugPrint('auto-queue: could not save the setting: $e');
    }
  }

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

  ArtistFocus? follow(Track song) {
    if (mode.value != AutoQueueMode.sameArtist) return null;
    final credit = ArtistCredit.of(song);
    final cur = focus.value;
    if (cur != null && (credit.isEmpty || credit.has(cur.name))) return cur;

    final searched = _searched;
    ArtistFocus? next;
    if (credit.isEmpty) {
      if (searched != null && searched.length <= 60) {
        next = ArtistFocus(searched, credit, checked: false);
      }
    } else {
      var name = (searched == null ? null : credit.named(searched)) ?? credit.main.first;
      var checked = true;
      final whole = credit.act;
      if (whole != null &&
          whole.length <= 80 &&
          credit.main.any((m) => ArtistCredit.norm(m) == ArtistCredit.norm(name))) {
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

  void confirm(ArtistFocus f, String name) {
    if (!identical(focus.value, f)) return;
    final whole = f.credit.act;
    if (whole != null && ArtistCredit.norm(whole) == ArtistCredit.norm(name)) {
      _acts.add(ArtistCredit.norm(whole));
    }
    focus.value = ArtistFocus(name, f.credit, checked: true);
  }

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
