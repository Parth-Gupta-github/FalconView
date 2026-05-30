import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/place.dart';
<<<<<<< Updated upstream
=======
import '../util/tile_math.dart';
import 'mbtiles_tile_source.dart';
import 'mbtiles_writer.dart';
import 'offline_router.dart';
>>>>>>> Stashed changes

class OfflineSearchIndex {
  OfflineSearchIndex({http.Client? client}) : _client = client ?? http.Client();

  static const String _overpass = 'https://overpass-api.de/api/interpreter';
  static const String _userAgent = 'FalconView/1.0 (contact: parvtiwari1@gmail.com)';

  final http.Client _client;
  // Read-only handles kept open for the lifetime of the service. Opening a
  // 30 MB SQLite file is 150–300 ms; doing it on every keystroke is what was
  // making the search feel sluggish after the router was added.
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

<<<<<<< Updated upstream
  Future<void> build(
=======
  /// Legacy online path: fetch loose MVT tiles over HTTP and extract directly,
  /// without persisting them. The download flow now fetches into an `.mbtiles`
  /// pack and calls [buildFromMbtiles] instead; this is retained as a
  /// network-only fallback and shares the same per-tile extraction helpers.
  Future<IndexBuildStats> build(
>>>>>>> Stashed changes
    int regionId,
    LatLngBounds bbox, {
    void Function(double percent)? onProgress,
  }) async {
    onProgress?.call(0);
    await _evict(regionId);
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
<<<<<<< Updated upstream
=======
  }

  /// Same output as [build] — a per-region POI + road-graph DB — but the tiles
  /// are read from a local `.mbtiles` file instead of fetched over HTTP, so no
  /// network is used. Tiles are processed in pages to bound memory on large
  /// (country-scale) files.
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
>>>>>>> Stashed changes
    if (res.statusCode != 200) {
      throw OfflineIndexException('Overpass failed (HTTP ${res.statusCode})');
    }
    onProgress?.call(60);

    final Map<String, dynamic> body = jsonDecode(res.body) as Map<String, dynamic>;
    final List<dynamic> elements = (body['elements'] as List<dynamic>?) ?? const <dynamic>[];

    final File file = await _dbFileFor(regionId);
    if (await file.exists()) await file.delete();

<<<<<<< Updated upstream
    final Database db = await openDatabase(
=======
  // ---------------- Tile enumeration + MVT decode ----------------

  List<_TileKey> _enumerateTiles(LatLngBounds bbox) =>
      _enumerateTilesRange(bbox, _zMin, _zMax);

  List<_TileKey> _enumerateTilesRange(LatLngBounds bbox, int zMin, int zMax) {
    final List<_TileKey> out = <_TileKey>[];
    for (int z = zMin; z <= zMax; z++) {
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

  /// Fetches every tile covering [bbox] across `[zMin..zMax]` and packs the
  /// raw (gzipped) bytes into [writer]. This is the network half of producing
  /// an offline MBTiles pack; the graph/POI build then reads it back via
  /// [buildFromMbtiles]. Missing tiles (HTTP errors) are simply skipped.
  Future<void> downloadRegionToMbtiles(
    MbtilesWriter writer,
    LatLngBounds bbox, {
    required int zMin,
    required int zMax,
    void Function(double percent)? onProgress,
  }) async {
    final String tileUrlTemplate = await _resolveTileUrlTemplate();
    final List<_TileKey> tiles = _enumerateTilesRange(bbox, zMin, zMax);
    final int total = tiles.length;
    int done = 0;
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
            return await _fetchTileRaw(url);
          } catch (_) {
            return null;
          }
        },
      ));
      for (int j = 0; j < chunk.length; j++) {
        final Uint8List? bytes = fetched[j];
        if (bytes != null && bytes.isNotEmpty) {
          await writer.put(chunk[j].z, chunk[j].x, chunk[j].y, bytes);
        }
      }
      done += chunk.length;
      if (total > 0) onProgress?.call(done / total * 100);
    }
    await writer.flush();
  }

  /// Like [_fetchTile] but returns the bytes verbatim (still gzipped) so they
  /// can be stored in an MBTiles file in the conventional encoding.
  Future<Uint8List?> _fetchTileRaw(String url) async {
    final http.Response res = await _client
        .get(Uri.parse(url), headers: <String, String>{
          'User-Agent': _userAgent,
        })
        .timeout(_tileTimeout);
    if (res.statusCode != 200) return null;
    return res.bodyBytes;
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
>>>>>>> Stashed changes
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

    const int chunkSize = 2000;
    Batch batch = db.batch();
    int pending = 0;
    int inserted = 0;
    const List<String> nameKeys = <String>[
      'name', 'alt_name', 'short_name', 'loc_name', 'name:en', 'official_name', 'nat_name', 'reg_name'
    ];
    Future<void> flush({bool force = false}) async {
      if (force || pending >= chunkSize) {
        await batch.commit(noResult: true, continueOnError: true);
        batch = db.batch();
        pending = 0;
      }
    }
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
        pending++;
        inserted++;
      }
      await flush();
    }
    await flush(force: true);
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

    final Database db = await _openForRead(regionId);
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

  Future<void> dispose() async {
    _client.close();
    for (final Database db in _readDbCache.values) {
      if (db.isOpen) await db.close();
    }
    _readDbCache.clear();
  }
}

class OfflineIndexException implements Exception {
  OfflineIndexException(this.message);
  final String message;
  @override
  String toString() => message;
}
