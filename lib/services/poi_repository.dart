import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/offline_poi.dart';

/// Stores OSM POIs per downloaded region.
///
/// One JSON blob per region under `poi_region_<id>`. This avoids pulling in
/// sqflite for what is realistically a few hundred KB per city. If POI volume
/// grows past ~5 MB total, swap to sqflite + an FTS5 index.
class PoiRepository {
  static const String _keyPrefix = 'poi_region_';

  Future<void> savePoisForRegion(int regionId, List<OfflinePoi> pois) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> raw =
          pois.map((p) => p.toJson()).toList();
      await prefs.setString('$_keyPrefix$regionId', jsonEncode(raw));
    } catch (e, s) {
      debugPrint('PoiRepository.save failed for region $regionId: $e\n$s');
    }
  }

  Future<List<OfflinePoi>> loadForRegion(int regionId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString('$_keyPrefix$regionId');
      return _decode(raw);
    } catch (e, s) {
      debugPrint('PoiRepository.loadForRegion $regionId failed: $e\n$s');
      return const <OfflinePoi>[];
    }
  }

  Future<List<OfflinePoi>> loadAll() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Iterable<String> keys =
          prefs.getKeys().where((k) => k.startsWith(_keyPrefix));
      final List<OfflinePoi> out = <OfflinePoi>[];
      for (final String key in keys) {
        out.addAll(_decode(prefs.getString(key)));
      }
      return out;
    } catch (e, s) {
      debugPrint('PoiRepository.loadAll failed: $e\n$s');
      return const <OfflinePoi>[];
    }
  }

  Future<List<OfflinePoi>> search(String query, {int limit = 30}) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return const <OfflinePoi>[];
    final List<OfflinePoi> all = await loadAll();
    final List<OfflinePoi> matches = <OfflinePoi>[];
    for (final OfflinePoi p in all) {
      if (p.name.toLowerCase().contains(q) ||
          p.category.toLowerCase().contains(q)) {
        matches.add(p);
        if (matches.length >= limit) break;
      }
    }
    return matches;
  }

  Future<void> deleteForRegion(int regionId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_keyPrefix$regionId');
    } catch (e, s) {
      debugPrint('PoiRepository.delete failed for region $regionId: $e\n$s');
    }
  }

  List<OfflinePoi> _decode(String? raw) {
    if (raw == null) return const <OfflinePoi>[];
    try {
      final List<dynamic> decoded = jsonDecode(raw) as List<dynamic>;
      final List<OfflinePoi> out = <OfflinePoi>[];
      for (final dynamic item in decoded) {
        if (item is Map<String, dynamic>) {
          try {
            out.add(OfflinePoi.fromJson(item));
          } catch (_) {
            // Skip malformed entries rather than failing the whole list.
          }
        }
      }
      return out;
    } catch (_) {
      return const <OfflinePoi>[];
    }
  }
}
