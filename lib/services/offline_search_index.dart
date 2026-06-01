import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:vector_tile/vector_tile.dart';

import '../models/place.dart';
import '../util/tile_math.dart';
import 'mbtiles_tile_source.dart';
import 'offline_router.dart';

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
    OfflineRouter? router,
    this._styleUrl = _defaultStyle,
  })  : _client = client ?? http.Client(),
        _router = router ?? OfflineRouter();

  final OfflineRouter _router;

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
    bool Function(double lat, double lon)? contains,
  }) async {
    onProgress?.call(0);
    // Stale reader on the old file would block the delete + reopen below.
    await _evict(regionId);

    final File outFile = await _dbFileFor(regionId);
    if (await outFile.exists()) await outFile.delete();
    final Database outDb = await _openOutDb(outFile);
    // Same DB also holds the road graph. OfflineRouter owns the schema.
    await _router.setupTables(outDb);

    int inserted = 0;
    int scanned = 0;
    int roadSegments = 0;
    final Set<int> seenNodes = <int>{};
    final Set<int> seenEdges = <int>{};
    try {
      final String tileUrlTemplate = await _resolveTileUrlTemplate();
      final List<_TileKey> tiles = _enumerateTiles(bbox);
      final int total = tiles.length;
      int doneTiles = 0;

      Batch poiBatch = outDb.batch();
      Batch nodeBatch = outDb.batch();
      Batch edgeBatch = outDb.batch();
      int poiPending = 0;
      int nodePending = 0;
      int edgePending = 0;
      Future<void> flush({bool force = false}) async {
        if (force || poiPending >= _chunkSize) {
          await poiBatch.commit(noResult: true, continueOnError: true);
          poiBatch = outDb.batch();
          poiPending = 0;
        }
        if (force || nodePending >= _chunkSize) {
          await nodeBatch.commit(noResult: true, continueOnError: true);
          nodeBatch = outDb.batch();
          nodePending = 0;
        }
        if (force || edgePending >= _chunkSize) {
          await edgeBatch.commit(noResult: true, continueOnError: true);
          edgeBatch = outDb.batch();
          edgePending = 0;
        }
      }

      // Fetch tiles in parallel chunks; decode POI + road graph from each
      // tile in the same pass — no duplicate downloads.
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
          final int added =
              _extractFromTile(poiBatch, bytes, t.z, t.x, t.y, contains);
          inserted += added;
          poiPending += added;
          // Roads are emitted by OpenMapTiles from z13 upward in any useful
          // density. Skip z12 for routing — its transportation features are
          // motorways only.
          if (t.z >= 13) {
            roadSegments += _router.extractFromTile(
              bytes: bytes,
              z: t.z,
              x: t.x,
              y: t.y,
              seenNodes: seenNodes,
              seenEdges: seenEdges,
              nodeBatch: nodeBatch,
              edgeBatch: edgeBatch,
              addedNodes: (int n) => nodePending += n,
              addedEdges: (int n) => edgePending += n,
              contains: contains,
            );
          }
        }
        await flush();
        doneTiles += chunk.length;
        if (total > 0) onProgress?.call(doneTiles / total * 95);
      }
      await flush(force: true);
      debugPrint(
        'MVT extract: scanned $scanned tiles, '
        '$inserted POIs, ${seenNodes.length} road nodes, '
        '$roadSegments road segments',
      );
    } catch (e, s) {
      debugPrint('MVT extract failed: $e\n$s');
    }

    await outDb.close();
    onProgress?.call(100);
    return IndexBuildStats(
      source: inserted > 0 ? PoiSource.mvt : PoiSource.none,
      tilesScanned: scanned,
      poisInserted: inserted,
    );
  }

  /// Same output as [build] (per-region POI + road-graph DB) but reads tiles
  /// from a local `.mbtiles` file instead of the network — no HTTP at all.
  /// Tiles are processed in pages to bound memory on large files.
  Future<IndexBuildStats> buildFromMbtiles(
    int regionId,
    MbtilesTileSource source, {
    void Function(double percent)? onProgress,
    bool Function(double lat, double lon)? contains,
  }) async {
    onProgress?.call(0);
    await _evict(regionId);
    final File outFile = await _dbFileFor(regionId);
    if (await outFile.exists()) await outFile.delete();
    final Database outDb = await _openOutDb(outFile);
    await _router.setupTables(outDb);

    int inserted = 0;
    int scanned = 0;
    int roadSegments = 0;
    final Set<int> seenNodes = <int>{};
    final Set<int> seenEdges = <int>{};
    try {
      final int total = await source.tileCount(_zMin, _zMax);
      int done = 0;

      Batch poiBatch = outDb.batch();
      Batch nodeBatch = outDb.batch();
      Batch edgeBatch = outDb.batch();
      int poiPending = 0;
      int nodePending = 0;
      int edgePending = 0;
      Future<void> flush({bool force = false}) async {
        if (force || poiPending >= _chunkSize) {
          await poiBatch.commit(noResult: true, continueOnError: true);
          poiBatch = outDb.batch();
          poiPending = 0;
        }
        if (force || nodePending >= _chunkSize) {
          await nodeBatch.commit(noResult: true, continueOnError: true);
          nodeBatch = outDb.batch();
          nodePending = 0;
        }
        if (force || edgePending >= _chunkSize) {
          await edgeBatch.commit(noResult: true, continueOnError: true);
          edgeBatch = outDb.batch();
          edgePending = 0;
        }
      }

      const int pageSize = 256;
      for (int z = _zMin; z <= _zMax; z++) {
        int offset = 0;
        while (true) {
          final List<MbtilesTile> page =
              await source.tilePage(z, pageSize, offset);
          if (page.isEmpty) break;
          for (final MbtilesTile t in page) {
            scanned++;
            done++;
            if (t.bytes.isEmpty) continue;
            final int added =
                _extractFromTile(poiBatch, t.bytes, z, t.x, t.y, contains);
            inserted += added;
            poiPending += added;
            if (z >= 13) {
              roadSegments += _router.extractFromTile(
                bytes: t.bytes,
                z: z,
                x: t.x,
                y: t.y,
                seenNodes: seenNodes,
                seenEdges: seenEdges,
                nodeBatch: nodeBatch,
                edgeBatch: edgeBatch,
                addedNodes: (int n) => nodePending += n,
                addedEdges: (int n) => edgePending += n,
                contains: contains,
              );
            }
          }
          await flush();
          if (total > 0) onProgress?.call(done / total * 95);
          if (page.length < pageSize) break;
          offset += pageSize;
        }
      }
      await flush(force: true);
      debugPrint(
        'MBTiles extract: scanned $scanned tiles, '
        '$inserted POIs, ${seenNodes.length} road nodes, '
        '$roadSegments road segments',
      );
    } catch (e, s) {
      debugPrint('MBTiles extract failed: $e\n$s');
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

  int _extractFromTile(
    Batch batch,
    Uint8List bytes,
    int z,
    int x,
    int y,
    bool Function(double lat, double lon)? contains,
  ) {
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
        // Clip to the user-drawn area when one was supplied.
        if (contains != null && !contains(ll[0], ll[1])) continue;
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

  /// Returns the nearest indexed POI within [maxMeters] of (lat, lon), or
  /// null if nothing is close. Used by the map-tap interaction in
  /// MapScreen — tap on a hospital icon → small bottom sheet with details.
  Future<Place?> nearest(
    int regionId,
    double lat,
    double lon, {
    double maxMeters = 50,
  }) async {
    final File file = await _dbFileFor(regionId);
    if (!await file.exists()) return null;
    // Prefilter via a lat/lon box, then haversine-rank the candidates.
    // 1° latitude ≈ 111 km. cos(lat) corrects longitude span at higher
    // latitudes (so 50 m east at 60°N covers more lon-degrees than at 0°N).
    final double dLat = maxMeters / 111000.0;
    final double cosLat =
        (lat.abs() < 89.5) ? math.cos(lat * math.pi / 180.0) : 0.01;
    final double dLon = maxMeters / (111000.0 * cosLat);
    final Database db = await _openForRead(regionId);
    final List<Map<String, dynamic>> rows = await db.rawQuery(
      '''
        SELECT name, category, lat, lon FROM features
        WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
        LIMIT 200
      ''',
      <Object?>[lat - dLat, lat + dLat, lon - dLon, lon + dLon],
    );
    if (rows.isEmpty) return null;
    Map<String, dynamic>? best;
    double bestDist = double.infinity;
    for (final Map<String, dynamic> r in rows) {
      final double rlat = (r['lat'] as num).toDouble();
      final double rlon = (r['lon'] as num).toDouble();
      final double d = _haversine(lat, lon, rlat, rlon);
      if (d < bestDist) {
        bestDist = d;
        best = r;
      }
    }
    if (best == null || bestDist > maxMeters) return null;
    return Place(
      name: best['name'] as String,
      subtitle: (best['category'] as String?) ?? '',
      center: LatLng(best['lat'] as double, best['lon'] as double),
      bbox: _smallBbox(best['lat'] as double, best['lon'] as double),
    );
  }

  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const double r = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180.0;
    final double dLon = (lon2 - lon1) * math.pi / 180.0;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180.0) *
            math.cos(lat2 * math.pi / 180.0) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
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
