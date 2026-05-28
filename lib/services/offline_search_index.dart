import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/place.dart';

class OfflineSearchIndex {
  OfflineSearchIndex({http.Client? client}) : _client = client ?? http.Client();

  static const String _overpass = 'https://overpass-api.de/api/interpreter';
  static const String _userAgent = 'FalconView/1.0 (contact: parvtiwari1@gmail.com)';

  final http.Client _client;

  Future<File> _dbFileFor(int regionId) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(docs.path, 'region_indexes'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, '$regionId.db'));
  }

  Future<bool> hasIndex(int regionId) async {
    final File f = await _dbFileFor(regionId);
    return f.exists();
  }

  Future<void> deleteIndex(int regionId) async {
    final File f = await _dbFileFor(regionId);
    if (await f.exists()) await f.delete();
  }

  Future<void> build(
    int regionId,
    LatLngBounds bbox, {
    void Function(double percent)? onProgress,
  }) async {
    onProgress?.call(0);
    final String s = bbox.southwest.latitude.toString();
    final String w = bbox.southwest.longitude.toString();
    final String n = bbox.northeast.latitude.toString();
    final String e = bbox.northeast.longitude.toString();
    final String bb = '$s,$w,$n,$e';

    final String query = '''
[out:json][timeout:90];
(
  node["place"]($bb);
  nwr["amenity"]["name"]($bb);
  nwr["shop"]["name"]($bb);
  nwr["tourism"]["name"]($bb);
  nwr["highway"]["name"]($bb);
  nwr["building"]["name"]($bb);
  nwr["natural"]["name"]($bb);
  nwr["leisure"]["name"]($bb);
  nwr["railway"]["name"]($bb);
  nwr["aeroway"]["name"]($bb);
);
out tags center;
''';

    final http.Response res = await _client.post(
      Uri.parse(_overpass),
      headers: <String, String>{
        'User-Agent': _userAgent,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{'data': query},
    );
    if (res.statusCode != 200) {
      throw OfflineIndexException('Overpass failed (HTTP ${res.statusCode})');
    }
    onProgress?.call(60);

    final Map<String, dynamic> body = jsonDecode(res.body) as Map<String, dynamic>;
    final List<dynamic> elements = (body['elements'] as List<dynamic>?) ?? const <dynamic>[];

    final File file = await _dbFileFor(regionId);
    if (await file.exists()) await file.delete();

    final Database db = await openDatabase(
      file.path,
      version: 1,
      onCreate: (Database db, int v) async {
        await db.execute('''
          CREATE TABLE features(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            name_lc TEXT NOT NULL,
            category TEXT,
            lat REAL NOT NULL,
            lon REAL NOT NULL
          )''');
        await db.execute(
            'CREATE INDEX features_name_lc_idx ON features(name_lc)');
      },
    );

    final Batch batch = db.batch();
    int inserted = 0;
    const List<String> nameKeys = <String>[
      'name', 'alt_name', 'short_name', 'loc_name', 'name:en', 'official_name', 'nat_name', 'reg_name'
    ];
    for (final dynamic el in elements) {
      if (el is! Map) continue;
      final Map<String, dynamic> m = el.cast<String, dynamic>();
      final Map<String, dynamic>? tags = (m['tags'] as Map?)?.cast<String, dynamic>();
      if (tags == null) continue;
      final double? lat = _asDouble(m['lat']) ?? _asDouble((m['center'] as Map?)?['lat']);
      final double? lon = _asDouble(m['lon']) ?? _asDouble((m['center'] as Map?)?['lon']);
      if (lat == null || lon == null) continue;

      // Collect every name variant, deduped, semicolon-split (OSM sometimes
      // stores "alt_name=MG Road;M.G. Road").
      final Set<String> names = <String>{};
      for (final String key in nameKeys) {
        final dynamic v = tags[key];
        if (v is! String) continue;
        for (final String part in v.split(';')) {
          final String trimmed = part.trim();
          if (trimmed.isNotEmpty) names.add(trimmed);
        }
      }
      if (names.isEmpty) continue;

      final String category = _categorize(tags);
      // Use the primary `name` for the display label when available; otherwise
      // the first variant.
      final String display = (tags['name'] as String?) ?? names.first;
      for (final String n in names) {
        batch.insert('features', <String, dynamic>{
          'name': display,
          'name_lc': n.toLowerCase(),
          'category': category,
          'lat': lat,
          'lon': lon,
        });
        inserted++;
      }
    }
    await batch.commit(noResult: true);
    await db.close();
    onProgress?.call(100);
    if (inserted == 0) {
      // Empty index is still valid (region might be very sparse); leave the file.
    }
  }

  Future<List<Place>> search(int regionId, String query, {int limit = 20}) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return const <Place>[];
    final File file = await _dbFileFor(regionId);
    if (!await file.exists()) return const <Place>[];

    final String safe = q.replaceAll('%', ' ').replaceAll('_', ' ').trim();
    if (safe.isEmpty) return const <Place>[];

    final Database db = await openDatabase(file.path, readOnly: true);
    // Two patterns: "starts with safe" (uses the index for fast prefix scan),
    // and "any word starts with safe" (catches "road" in "MG Road").
    final List<Map<String, dynamic>> rows = await db.rawQuery(
      '''
        SELECT name, category, lat, lon FROM features
        WHERE name_lc LIKE ? OR name_lc LIKE ?
        LIMIT ?
      ''',
      <Object?>['$safe%', '% $safe%', limit],
    );
    await db.close();
    return rows
        .map((Map<String, dynamic> r) => Place(
              name: r['name'] as String,
              subtitle: (r['category'] as String?) ?? '',
              center: LatLng(r['lat'] as double, r['lon'] as double),
              bbox: _smallBbox(r['lat'] as double, r['lon'] as double),
            ))
        .toList();
  }

  String _categorize(Map<String, dynamic> t) {
    if (t['place'] != null) return 'place · ${t['place']}';
    if (t['amenity'] != null) return 'amenity · ${t['amenity']}';
    if (t['shop'] != null) return 'shop · ${t['shop']}';
    if (t['tourism'] != null) return 'tourism · ${t['tourism']}';
    if (t['leisure'] != null) return 'leisure · ${t['leisure']}';
    if (t['natural'] != null) return 'natural · ${t['natural']}';
    if (t['building'] != null) return 'building';
    if (t['highway'] != null) return 'street';
    return '';
  }

  double? _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  LatLngBounds _smallBbox(double lat, double lon) {
    const double d = 0.002;
    return LatLngBounds(
      southwest: LatLng(lat - d, lon - d),
      northeast: LatLng(lat + d, lon + d),
    );
  }

  void dispose() => _client.close();
}

class OfflineIndexException implements Exception {
  OfflineIndexException(this.message);
  final String message;
  @override
  String toString() => message;
}
