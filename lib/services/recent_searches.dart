import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/place.dart';

/// Persists the last [_maxItems] places the user picked from search so the
/// empty search state can show them as quick re-pick suggestions.
///
/// Storage is a single JSON string in SharedPreferences — small (<2 KB even
/// at the cap), atomic, and survives app reinstalls when SharedPrefs is
/// backed up by the OS.
class RecentSearchesStore {
  RecentSearchesStore();

  static const String _key = 'recent_searches_v1';
  static const int _maxItems = 8;

  /// Returns the saved list, most-recent first. Empty list on any read error
  /// or first launch — never throws.
  Future<List<Place>> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const <Place>[];
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <Place>[];
      final List<Place> out = <Place>[];
      for (final dynamic item in decoded) {
        if (item is! Map) continue;
        try {
          out.add(Place.fromJson(item.cast<String, dynamic>()));
        } catch (_) {
          // Skip malformed entries — likely a schema bump from older versions.
        }
      }
      return out;
    } catch (_) {
      return const <Place>[];
    }
  }

  /// Adds [place] to the front of the list. If a near-duplicate (same name +
  /// roughly same coords) already exists it gets moved to the front instead
  /// of duplicated. Oldest entries are evicted past [_maxItems].
  Future<void> add(Place place) async {
    try {
      final List<Place> current = List<Place>.from(await load());
      final String key = _dedupKey(place);
      current.removeWhere((Place p) => _dedupKey(p) == key);
      current.insert(0, place);
      while (current.length > _maxItems) {
        current.removeLast();
      }
      await _save(current);
    } catch (_) {
      // Persistence failure is non-fatal — recents just won't grow.
    }
  }

  /// Removes the entry matching [place] by dedup key. No-op if not found.
  Future<void> remove(Place place) async {
    try {
      final List<Place> current = List<Place>.from(await load());
      final String key = _dedupKey(place);
      final int before = current.length;
      current.removeWhere((Place p) => _dedupKey(p) == key);
      if (current.length == before) return; // nothing changed
      await _save(current);
    } catch (_) {}
  }

  /// Wipes the whole list.
  Future<void> clear() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }

  Future<void> _save(List<Place> list) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String encoded =
        jsonEncode(list.map((Place p) => p.toJson()).toList());
    await prefs.setString(_key, encoded);
  }

  /// Two places dedupe when their names match (case-insensitive) AND their
  /// coords agree within ~1 km. Keeps "Mumbai" from showing twice if the
  /// user picks two slightly different Mumbai results from search.
  String _dedupKey(Place p) {
    return '${p.name.trim().toLowerCase()}|'
        '${(p.center.latitude * 100).round()}|'
        '${(p.center.longitude * 100).round()}';
  }
}

/// App-wide singleton.
final RecentSearchesStore recentSearchesStore = RecentSearchesStore();
