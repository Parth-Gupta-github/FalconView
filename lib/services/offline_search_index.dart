import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:vector_tile/vector_tile.dart';

import '../models/place.dart';
import '../util/tile_math.dart';

class OfflineIndexException implements Exception {
  OfflineIndexException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Which data source ended up populating the per-region index.
/// MBTiles is the only real source now (no Overpass fallback).
enum PoiSource { mvt, none }

extension PoiSourceLabel on PoiSource {
  String get label {
    switch (this) {
      case PoiSource.mvt:
        return 'MBTiles';
      case PoiSource.none:
        return 'None';
    }
  }
}

/// Result of building a per-region index. Surfaced to the UI so the user
/// sees diagnostic counts without having to read terminal logs.
class IndexBuildStats {
  final PoiSource source;
  final int tilesScanned;
  final int poisInserted;
  const IndexBuildStats({
    required this.source,
    required this.tilesScanned,
    required this.poisInserted,
  });
}

/// Builds a per-region SQLite POI index by directly fetching MVT vector tiles
/// from the style's tile source and decoding the `poi` + `place` layers.
///
/// Trade-off accepted: tiles are fetched twice (once by MapLibre Native for
/// rendering, once by us for POI extraction). In exchange we get:
///  - No dependency on MapLibre Native's internal cache schema/path
///  - No external API call (no Overpass)
///  - Deterministic behavior across platforms
class OfflineSearchIndex {
  OfflineSearchIndex({
    http.Client? client,
    this._styleUrl = _defaultStyle,
  }) : _client = client ?? http.Client();

  static const String _defaultStyle =
      'https://tiles.openfreemap.org/styles/liberty';
  static const String _userAgent =
      'FalconView/1.0 (offline POI index; contact: tarun@igismap.com)';

  // OpenMapTiles emits POIs from z12 upward. Source maxzoom is 14 — higher
  // zoom levels just render the z14 data larger, so they contain no new POIs.
  static const int _zMin = 12;
  static const int _zMax = 14;

  static const Duration _tileTimeout = Duration(seconds: 10);

  // Flush the SQLite Batch every N inserts. Platform-channel decoder OOMs at
  // ~200k pending ops, so we keep the chunk well under that.
  static const int _chunkSize = 2000;

  final http.Client _client;
  final String _styleUrl;
  String? _cachedTileUrlTemplate;

  // Read-only handles kept open for the lifetime of the service. Opening a
  // 30 MB SQLite file is 150–300 ms; doing it on every keystroke was making
  // the search feel sluggish.
  final Map<int, Database> _readDbCache = <int, Database>{};

  Future<Database> _openForRead(int regionId) async {
    final Database? cached = _readDbCache[regionId];
    if (cached != null && cached.isOpen) return cached;
    final File file = await _dbFileFor(regionId);
    final Database db = await openDatabase(file.path, readOnly: true);
    _readDbCache[regionId] = db;
    return db;
  }

  Future<void> _evict(int regionId) async {
    final Database? db = _readDbCache.remove(regionId);
    if (db != null && db.isOpen) await db.close();
  }

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
    await _evict(regionId);
    final File f = await _dbFileFor(regionId);
    if (await f.exists()) await f.delete();
  }

  Future<IndexBuildStats> build(
    int regionId,
    LatLngBounds bbox, {
    void Function(double percent)? onProgress,
  }) async {
    onProgress?.call(0);
    // Stale reader on the old file would block the delete + reopen below.
    await _evict(regionId);

    final File outFile = await _dbFileFor(regionId);
    if (await outFile.exists()) await outFile.delete();
    final Database outDb = await _openOutDb(outFile);

    int inserted = 0;
    int scanned = 0;
    try {
      final String tileUrlTemplate = await _resolveTileUrlTemplate();
      final List<_TileKey> tiles = _enumerateTiles(bbox);
      final int total = tiles.length;
      int doneTiles = 0;

      Batch batch = outDb.batch();
      int pending = 0;
      Future<void> flush({bool force = false}) async {
        if (force || pending >= _chunkSize) {
          await batch.commit(noResult: true, continueOnError: true);
          batch = outDb.batch();
          pending = 0;
        }
      }

      // Fetch tiles in parallel chunks — single-tile serial fetching was the
      // bottleneck; the CDN happily serves dozens of concurrent requests.
      const int concurrency = 8;
      for (int i = 0; i < tiles.length; i += concurrency) {
        final int end =
            (i + concurrency < tiles.length) ? i + concurrency : tiles.length;
        final List<_TileKey> chunk = tiles.sublist(i, end);
        final List<Uint8List?> fetched = await Future.wait(chunk.map(
          (_TileKey t) async {
            final String url = tileUrlTemplate
                .replaceAll('{z}', '${t.z}')
                .replaceAll('{x}', '${t.x}')
                .replaceAll('{y}', '${t.y}');
            try {
              return await _fetchTile(url);
            } catch (_) {
              return null;
            }
          },
        ));
        for (int j = 0; j < chunk.length; j++) {
          scanned++;
          final Uint8List? bytes = fetched[j];
          if (bytes == null || bytes.isEmpty) continue;
          final _TileKey t = chunk[j];
          final int added = _extractFromTile(batch, bytes, t.z, t.x, t.y);
          inserted += added;
          pending += added;
        }
        await flush();
        doneTiles += chunk.length;
        if (total > 0) onProgress?.call(doneTiles / total * 95);
      }
      await flush(force: true);
      debugPrint(
        'MVT extract: scanned $scanned tiles, inserted $inserted features',
      );
    } catch (e, s) {
      debugPrint('MVT POI extract failed: $e\n$s');
    }

    await outDb.close();
    onProgress?.call(100);
    return IndexBuildStats(
      source: inserted > 0 ? PoiSource.mvt : PoiSource.none,
      tilesScanned: scanned,
      poisInserted: inserted,
    );
  }

  // ---------------- Style + tile URL resolution ----------------

  Future<String> _resolveTileUrlTemplate() async {
    final String? cached = _cachedTileUrlTemplate;
    if (cached != null) return cached;

    final http.Response res = await _client
        .get(Uri.parse(_styleUrl), headers: <String, String>{
          'User-Agent': _userAgent,
        })
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw OfflineIndexException(
        'Failed to fetch style.json: HTTP ${res.statusCode}',
      );
    }
    final Map<String, dynamic> style =
        jsonDecode(res.body) as Map<String, dynamic>;
    final Map<String, dynamic>? sources =
        (style['sources'] as Map?)?.cast<String, dynamic>();
    if (sources == null) {
      throw OfflineIndexException('Style has no `sources` object');
    }
    for (final MapEntry<String, dynamic> entry in sources.entries) {
      final dynamic srcAny = entry.value;
      if (srcAny is! Map) continue;
      final Map<String, dynamic> src = srcAny.cast<String, dynamic>();
      if (src['type'] != 'vector') continue;

      final dynamic tilesField = src['tiles'];
      if (tilesField is List && tilesField.isNotEmpty) {
        final String tpl = tilesField.first as String;
        _cachedTileUrlTemplate = tpl;
        return tpl;
      }
      final dynamic urlField = src['url'];
      if (urlField is String && urlField.isNotEmpty) {
        final http.Response tjRes = await _client
            .get(Uri.parse(urlField), headers: <String, String>{
              'User-Agent': _userAgent,
            })
            .timeout(const Duration(seconds: 15));
        if (tjRes.statusCode != 200) continue;
        final Map<String, dynamic> tj =
            jsonDecode(tjRes.body) as Map<String, dynamic>;
        final dynamic tjTiles = tj['tiles'];
        if (tjTiles is List && tjTiles.isNotEmpty) {
          final String tpl = tjTiles.first as String;
          _cachedTileUrlTemplate = tpl;
          return tpl;
        }
      }
    }
    throw OfflineIndexException('No vector tile URL found in style');
  }

  Future<Uint8List?> _fetchTile(String url) async {
    final http.Response res = await _client
        .get(Uri.parse(url), headers: <String, String>{
          'User-Agent': _userAgent,
        })
        .timeout(_tileTimeout);
    if (res.statusCode != 200) return null;
    final Uint8List body = res.bodyBytes;
    if (body.length >= 2 && body[0] == 0x1f && body[1] == 0x8b) {
      return Uint8List.fromList(const GZipDecoder().decodeBytes(body));
    }
    return body;
  }

  // ---------------- Tile enumeration + MVT decode ----------------

  List<_TileKey> _enumerateTiles(LatLngBounds bbox) {
    final List<_TileKey> out = <_TileKey>[];
    for (int z = _zMin; z <= _zMax; z++) {
      final TileXY tl = TileMath.latLngToTile(
        bbox.northeast.latitude, bbox.southwest.longitude, z,
      );
      final TileXY br = TileMath.latLngToTile(
        bbox.southwest.latitude, bbox.northeast.longitude, z,
      );
      final int xMin = tl.x < br.x ? tl.x : br.x;
      final int xMax = tl.x < br.x ? br.x : tl.x;
      final int yMin = tl.y < br.y ? tl.y : br.y;
      final int yMax = tl.y < br.y ? br.y : tl.y;
      for (int x = xMin; x <= xMax; x++) {
        for (int y = yMin; y <= yMax; y++) {
          out.add(_TileKey(z, x, y));
        }
      }
    }
    return out;
  }

  int _extractFromTile(Batch batch, Uint8List bytes, int z, int x, int y) {
    final VectorTile tile;
    try {
      tile = VectorTile.fromBytes(bytes: bytes);
    } catch (_) {
      return 0;
    }
    int added = 0;
    for (final VectorTileLayer layer in tile.layers) {
      if (layer.name != 'poi' && layer.name != 'place') continue;
      final int extent = layer.extent;
      for (final VectorTileFeature feature in layer.features) {
        final Map<String, dynamic> props = _decodeProps(feature);
        final String? name = props['name'] as String?;
        if (name == null || name.isEmpty) continue;

        final List<num>? point = _firstPoint(feature);
        if (point == null) continue;

        final List<double> ll = TileMath.tilePixelToLatLng(
          z, x, y, point[0], point[1], extent,
        );
        batch.insert('features', <String, dynamic>{
          'name': name,
          'name_lc': name.toLowerCase(),
          'category': _category(layer.name, props),
          'lat': ll[0],
          'lon': ll[1],
        });
        added++;
      }
    }
    return added;
  }

  Map<String, dynamic> _decodeProps(VectorTileFeature feature) {
    final Map<String, dynamic> out = <String, dynamic>{};
    feature.decodeProperties();
    final Map<String, VectorTileValue>? props = feature.properties;
    if (props == null) return out;
    for (final MapEntry<String, VectorTileValue> e in props.entries) {
      final VectorTileValue v = e.value;
      if (v.stringValue != null) {
        out[e.key] = v.stringValue;
      } else if (v.intValue != null) {
        out[e.key] = v.intValue?.toInt();
      } else if (v.doubleValue != null) {
        out[e.key] = v.doubleValue;
      } else if (v.boolValue != null) {
        out[e.key] = v.boolValue;
      }
    }
    return out;
  }

  /// Extracts a single tile-local (x, y) point from a feature's geometry.
  /// For ways/polygons we use the first vertex as the label location.
  List<num>? _firstPoint(VectorTileFeature feature) {
    final Geometry? geom = feature.decodeGeometry<Geometry>();
    if (geom == null) return null;
    if (geom is GeometryPoint) {
      if (geom.coordinates.length >= 2) {
        return <num>[geom.coordinates[0], geom.coordinates[1]];
      }
    } else if (geom is GeometryMultiPoint) {
      if (geom.coordinates.isNotEmpty && geom.coordinates.first.length >= 2) {
        return <num>[geom.coordinates.first[0], geom.coordinates.first[1]];
      }
    } else if (geom is GeometryLineString) {
      if (geom.coordinates.isNotEmpty && geom.coordinates.first.length >= 2) {
        return <num>[geom.coordinates.first[0], geom.coordinates.first[1]];
      }
    } else if (geom is GeometryPolygon) {
      if (geom.coordinates.isNotEmpty &&
          geom.coordinates.first.isNotEmpty &&
          geom.coordinates.first.first.length >= 2) {
        return <num>[
          geom.coordinates.first.first[0],
          geom.coordinates.first.first[1],
        ];
      }
    }
    return null;
  }

  String _category(String layer, Map<String, dynamic> props) {
    if (layer == 'place') {
      final String cls = (props['class'] as String?) ?? 'place';
      return 'place · $cls';
    }
    final String cls = (props['class'] as String?) ?? 'poi';
    final String? sub = props['subclass'] as String?;
    if (sub != null && sub.isNotEmpty && sub != cls) return '$cls · $sub';
    return cls;
  }

  Future<Database> _openOutDb(File file) {
    return openDatabase(
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
          'CREATE INDEX features_name_lc_idx ON features(name_lc)',
        );
      },
    );
  }

  // ---------------- Search ----------------

  Future<List<Place>> search(int regionId, String query,
      {int limit = 20}) async {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return const <Place>[];
    final File file = await _dbFileFor(regionId);
    if (!await file.exists()) return const <Place>[];

    final String safe = q.replaceAll('%', ' ').replaceAll('_', ' ').trim();
    if (safe.isEmpty) return const <Place>[];

    final Database db = await _openForRead(regionId);
    final List<Map<String, dynamic>> rows = await db.rawQuery(
      '''
        SELECT name, category, lat, lon FROM features
        WHERE name_lc LIKE ? OR name_lc LIKE ?
        LIMIT ?
      ''',
      <Object?>['$safe%', '% $safe%', limit],
    );
    return rows
        .map((Map<String, dynamic> r) => Place(
              name: r['name'] as String,
              subtitle: (r['category'] as String?) ?? '',
              center: LatLng(r['lat'] as double, r['lon'] as double),
              bbox: _smallBbox(r['lat'] as double, r['lon'] as double),
            ))
        .toList();
  }

  LatLngBounds _smallBbox(double lat, double lon) {
    const double d = 0.002;
    return LatLngBounds(
      southwest: LatLng(lat - d, lon - d),
      northeast: LatLng(lat + d, lon + d),
    );
  }

  Future<void> dispose() async {
    _client.close();
    for (final Database db in _readDbCache.values) {
      if (db.isOpen) await db.close();
    }
    _readDbCache.clear();
  }
}

class _TileKey {
  final int z;
  final int x;
  final int y;
  const _TileKey(this.z, this.x, this.y);
}
