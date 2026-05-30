import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:vector_tile/vector_tile.dart';

import '../models/place.dart';
import '../util/tile_math.dart';
import 'bundled_basemap_server.dart';

/// Builds and queries a search index of administrative places (countries,
/// states, cities, towns, villages, suburbs) extracted from the bundled
/// Planetiler-generated MBTiles. Replaces Nominatim for "name → place"
/// lookups so the app needs no network for search.
///
/// The OpenMapTiles `place` layer is present from z0 upward, so a z0–6
/// bundled MBTiles covers every populated place we'd want to navigate to at
/// political/city granularity. POI search (restaurants, shops) still relies
/// on per-region downloaded indexes — those need z12+ tiles that aren't in
/// the global bundle.
///
/// Lifecycle: first call to [search] triggers a one-time scan of every tile
/// in the MBTiles (~5,500 tiles at z0–6, takes a few seconds on a modern
/// phone). The resulting SQLite FTS5 index is cached at
/// `<appDocs>/bundled_places.db` and reused across launches.
class BundledPlaceIndex {
  BundledPlaceIndex();

  static const String _indexFileName = 'bundled_places.db';
  static const String _materializedMbtilesName = 'bundled_basemap.mbtiles';

  Database? _db;
  Future<Database>? _ensureInFlight;
  int _builtCount = 0;
  bool _hasBuilt = false;
  String? _lastBuildError;

  /// Number of places currently indexed. 0 can mean "build ran and found
  /// nothing" OR "build hasn't happened yet" — use [hasBuilt] to disambiguate.
  int get builtCount => _builtCount;

  /// True once [_ensureBuilt] has completed (successfully or not). Use to tell
  /// "no results, but the index is built" from "no results because no index".
  bool get hasBuilt => _hasBuilt;

  /// Last error message from a failed build, or null if the last build
  /// succeeded. Useful for debug UI.
  String? get lastBuildError => _lastBuildError;

  /// Returns places matching [query] ranked by importance (countries first,
  /// then states, cities, towns, …). Triggers a one-time index build on
  /// first call. Returns empty list if the bundled MBTiles isn't present
  /// OR if any build / query step fails — search degrades silently so the
  /// UI shows "no results" rather than a stack trace.
  Future<List<Place>> search(String query, {int limit = 20}) async {
    final String q = query.trim();
    if (q.isEmpty) return const <Place>[];
    final String pattern = _toLikePattern(q);
    if (pattern.isEmpty) return const <Place>[];
    try {
      final Database db = await _ensureBuilt();
      // Plain LIKE on an indexed lowercase column — works on every SQLite
      // build (Realme/Oppo/Vivo etc. sometimes ship without FTS5). With an
      // index on name_lc this scans only matching rows; for low-zoom bundles
      // the place table is at most a few thousand rows, so query is sub-ms.
      final List<Map<String, Object?>> rows = await db.rawQuery(
        '''
        SELECT id, name, class, lat, lon, rank
        FROM places
        WHERE name_lc LIKE ?
        ORDER BY rank ASC, length(name) ASC
        LIMIT ?
        ''',
        <Object?>[pattern, limit],
      );
      return rows.map(_rowToPlace).toList();
    } catch (e, s) {
      debugPrint('BundledPlaceIndex.search failed: $e\n$s');
      return const <Place>[];
    }
  }

  /// True once the index has been built (or determined empty). Useful for
  /// UI to show a one-time "preparing search…" hint on first launch.
  Future<bool> isReady() async {
    final Database? cached = _db;
    if (cached != null && cached.isOpen) return true;
    final File f = await _indexFile();
    return f.exists();
  }

  /// Idempotent. First caller triggers the build/open; parallel callers
  /// share the same future and don't kick off duplicate work.
  Future<Database> _ensureBuilt() async {
    final Database? cached = _db;
    if (cached != null && cached.isOpen) return cached;
    final Future<Database>? inFlight = _ensureInFlight;
    if (inFlight != null) return inFlight;
    final Completer<Database> c = Completer<Database>();
    _ensureInFlight = c.future;
    try {
      final Database db = await _buildOrOpen();
      _db = db;
      _hasBuilt = true;
      _lastBuildError = null;
      debugPrint(
        'BundledPlaceIndex ready: $_builtCount places indexed.',
      );
      c.complete(db);
      return db;
    } catch (e, s) {
      _hasBuilt = true; // we tried — don't keep retrying
      _lastBuildError = '$e';
      debugPrint('BundledPlaceIndex build threw: $e\n$s');
      c.completeError(e);
      rethrow;
    } finally {
      _ensureInFlight = null;
    }
  }

  /// Public entry to trigger the build proactively (e.g. from app startup),
  /// so search isn't the first thing that has to wait for the scan.
  Future<void> warmUp() async {
    try {
      await _ensureBuilt();
    } catch (_) {
      // _ensureBuilt already recorded the error; UI surfaces it.
    }
  }

  Future<Database> _buildOrOpen() async {
    final File outFile = await _indexFile();
    if (await outFile.exists() && (await outFile.length()) > 0) {
      try {
        final Database db = await openDatabase(
          outFile.path,
          readOnly: true,
          singleInstance: false,
        );
        // Verify the schema looks right; older builds may have used FTS5
        // and left a half-baked file behind. If the query throws, scrap it.
        final List<Map<String, Object?>> count =
            await db.rawQuery('SELECT COUNT(1) AS n FROM places');
        _builtCount = (count.first['n']! as num).toInt();
        return db;
      } catch (e) {
        debugPrint('BundledPlaceIndex: stale index, rebuilding ($e)');
        await outFile.delete();
      }
    }
    return _build(outFile);
  }

  Future<File> _indexFile() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File(p.join(dir.path, _indexFileName));
  }

  Future<Database> _build(File outFile) async {
    debugPrint('BundledPlaceIndex: starting build → ${outFile.path}');
    final File? mbtiles = await _materializedMbtiles();
    final Database outDb = await _openSchemaDb(outFile.path);
    if (mbtiles == null) {
      debugPrint(
        'BundledPlaceIndex: no bundled MBTiles — empty index. '
        'Run tools/planetiler/generate to enable offline place search.',
      );
      await outDb.close();
      return openDatabase(
        outFile.path,
        readOnly: true,
        singleInstance: false,
      );
    }
    debugPrint('BundledPlaceIndex: reading from ${mbtiles.path}');
    // singleInstance:false → get our OWN sqflite connection. The default
    // (true) returns the same cached handle the BundledBasemapServer holds,
    // so when we close srcDb below we'd close the server's tile DB too.
    // That was the source of "BundledBasemapServer handler error:
    // DatabaseException(error database_closed)" spam in the log.
    final Database srcDb = await openDatabase(
      mbtiles.path,
      readOnly: true,
      singleInstance: false,
    );
    final Map<String, _PlaceRecord> dedup = <String, _PlaceRecord>{};
    try {
      // Read tiles highest-zoom-first so the most-precise location wins on dedup.
      final List<Map<String, Object?>> tileRows = await srcDb.query(
        'tiles',
        columns: <String>[
          'zoom_level',
          'tile_column',
          'tile_row',
          'tile_data',
        ],
        orderBy: 'zoom_level DESC',
      );
      for (final Map<String, Object?> row in tileRows) {
        final int z = (row['zoom_level']! as num).toInt();
        final int x = (row['tile_column']! as num).toInt();
        final int tmsY = (row['tile_row']! as num).toInt();
        final int y = ((1 << z) - 1) - tmsY; // MBTiles TMS → XYZ
        final Uint8List bytes = _gunzipIfNeeded(row['tile_data']! as Uint8List);
        _extractFromTile(bytes, z, x, y, dedup);
      }
      Batch batch = outDb.batch();
      int pending = 0;
      for (final _PlaceRecord r in dedup.values) {
        batch.insert('places', <String, Object?>{
          'name': r.name,
          'name_lc': r.name.toLowerCase(),
          'class': r.cls,
          'lat': r.lat,
          'lon': r.lon,
          'rank': r.rank,
        });
        pending++;
        if (pending >= 2000) {
          await batch.commit(noResult: true);
          batch = outDb.batch();
          pending = 0;
        }
      }
      if (pending > 0) await batch.commit(noResult: true);
      _builtCount = dedup.length;
      debugPrint(
        'BundledPlaceIndex: built $_builtCount places from '
        '${tileRows.length} tiles. Sample: '
        '${dedup.values.take(5).map((r) => "${r.name}(${r.cls})").join(", ")}',
      );
    } catch (e, s) {
      debugPrint('BundledPlaceIndex build failed: $e\n$s');
    } finally {
      await srcDb.close();
      await outDb.close();
    }
    return openDatabase(
      outFile.path,
      readOnly: true,
      singleInstance: false,
    );
  }

  Future<Database> _openSchemaDb(String path) async {
    return openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int v) async {
        await db.execute('''
          CREATE TABLE places(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            name_lc TEXT NOT NULL,
            class TEXT,
            lat REAL NOT NULL,
            lon REAL NOT NULL,
            rank INTEGER NOT NULL
          )
        ''');
        // Index on the lowercase name so LIKE 'prefix%' uses it as a range
        // scan instead of a full-table scan. Avoids depending on FTS5, which
        // isn't compiled into every Android device's SQLite.
        await db.execute('CREATE INDEX places_name_lc ON places(name_lc)');
        await db.execute('CREATE INDEX places_rank ON places(rank)');
      },
    );
  }

  /// Reuses the materialized MBTiles file that [BundledBasemapServer] copies
  /// out of `rootBundle` on first use. Calling [bundledBasemapServer.ensureStarted]
  /// is idempotent and guarantees the file is on disk if the asset shipped.
  Future<File?> _materializedMbtiles() async {
    await bundledBasemapServer.ensureStarted();
    final Directory dir = await getApplicationDocumentsDirectory();
    final File f = File(p.join(dir.path, _materializedMbtilesName));
    if (!await f.exists() || (await f.length()) == 0) return null;
    return f;
  }

  Uint8List _gunzipIfNeeded(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      return Uint8List.fromList(const GZipDecoder().decodeBytes(bytes));
    }
    return bytes;
  }

  void _extractFromTile(
    Uint8List bytes,
    int z,
    int x,
    int y,
    Map<String, _PlaceRecord> dedup,
  ) {
    final VectorTile tile;
    try {
      tile = VectorTile.fromBytes(bytes: bytes);
    } catch (_) {
      return;
    }
    for (final VectorTileLayer layer in tile.layers) {
      if (layer.name != 'place') continue;
      final int extent = layer.extent;
      for (final VectorTileFeature feature in layer.features) {
        feature.decodeProperties();
        final Map<String, VectorTileValue>? props = feature.properties;
        if (props == null) continue;
        final String? name = _stringProp(props['name']);
        if (name == null || name.isEmpty) continue;
        final String cls = _stringProp(props['class']) ?? 'place';
        final int? sourceRank = _intProp(props['rank']);
        final List<num>? pt = _firstPoint(feature);
        if (pt == null) continue;
        final List<double> ll =
            TileMath.tilePixelToLatLng(z, x, y, pt[0], pt[1], extent);
        // Dedup key collapses the same name within ~1 km radius across tiles
        // and zooms. Tiles are visited high-z → low-z, so the higher-z (more
        // precise) hit wins.
        final String key = '${name.toLowerCase()}|'
            '${(ll[0] * 100).round()}|'
            '${(ll[1] * 100).round()}';
        if (dedup.containsKey(key)) continue;
        dedup[key] = _PlaceRecord(
          name: name,
          cls: cls,
          lat: ll[0],
          lon: ll[1],
          rank: _rankFor(cls, sourceRank),
        );
      }
    }
  }

  String? _stringProp(VectorTileValue? v) =>
      v?.stringValue?.isEmpty == false ? v?.stringValue : null;

  int? _intProp(VectorTileValue? v) {
    if (v == null) return null;
    if (v.intValue != null) return v.intValue?.toInt();
    if (v.doubleValue != null) return v.doubleValue!.toInt();
    return null;
  }

  /// Ordering: smaller = more important. Reads OpenMapTiles' own `rank`
  /// field when present (countries are 1-3, big cities are low single digits,
  /// villages are mid-teens) and falls back to a class-based default.
  int _rankFor(String cls, int? sourceRank) {
    int base;
    switch (cls) {
      case 'country':
        base = 0;
        break;
      case 'state':
      case 'province':
        base = 100;
        break;
      case 'city':
        base = 200;
        break;
      case 'town':
        base = 400;
        break;
      case 'village':
        base = 600;
        break;
      case 'hamlet':
        base = 700;
        break;
      case 'suburb':
      case 'neighbourhood':
      case 'quarter':
        base = 800;
        break;
      default:
        base = 1000;
    }
    return base + (sourceRank ?? 50);
  }

  List<num>? _firstPoint(VectorTileFeature feature) {
    final Geometry? geom = feature.decodeGeometry<Geometry>();
    if (geom is GeometryPoint && geom.coordinates.length >= 2) {
      return <num>[geom.coordinates[0], geom.coordinates[1]];
    }
    if (geom is GeometryMultiPoint &&
        geom.coordinates.isNotEmpty &&
        geom.coordinates.first.length >= 2) {
      return <num>[geom.coordinates.first[0], geom.coordinates.first[1]];
    }
    return null;
  }

  /// Turns a free-text query into a SQL LIKE pattern. We lowercase the input
  /// (column is `name_lc`), strip SQL LIKE wildcards (`%` and `_`) and the
  /// LIKE escape character (`\`), and append `%` for prefix matching.
  ///
  /// Example: "Mon" -> "mon%" → matches "Monaco", "Monte-Carlo", "Monrovia".
  String _toLikePattern(String q) {
    final String cleaned = q
        .toLowerCase()
        .replaceAll(RegExp(r'[%_\\]'), '');
    if (cleaned.isEmpty) return '';
    return '$cleaned%';
  }

  Place _rowToPlace(Map<String, Object?> row) {
    final String name = row['name']! as String;
    final String? cls = row['class'] as String?;
    final double lat = (row['lat']! as num).toDouble();
    final double lon = (row['lon']! as num).toDouble();
    final int rank = (row['rank']! as num).toInt();
    // Synthesize a bbox sized by importance — same approach Nominatim takes
    // when it lacks one. Used by the map's "fly to bbox" animation.
    final double d;
    if (rank < 100) {
      d = 5.0; // country
    } else if (rank < 200) {
      d = 1.5; // state
    } else if (rank < 400) {
      d = 0.2; // city
    } else if (rank < 600) {
      d = 0.05; // town
    } else {
      d = 0.02; // village / suburb / other
    }
    return Place(
      name: name,
      subtitle: cls != null ? 'place · $cls' : 'place',
      center: LatLng(lat, lon),
      bbox: LatLngBounds(
        southwest: LatLng(lat - d, lon - d),
        northeast: LatLng(lat + d, lon + d),
      ),
    );
  }

  /// Forces a fresh rebuild on the next [search]. Call this if the bundled
  /// MBTiles asset is regenerated with different coverage.
  Future<void> reset() async {
    final Database? cached = _db;
    _db = null;
    if (cached != null && cached.isOpen) await cached.close();
    final File f = await _indexFile();
    if (await f.exists()) await f.delete();
    _builtCount = 0;
  }
}

class _PlaceRecord {
  _PlaceRecord({
    required this.name,
    required this.cls,
    required this.lat,
    required this.lon,
    required this.rank,
  });
  final String name;
  final String cls;
  final double lat;
  final double lon;
  final int rank;
}

/// App-wide singleton. The first call to [search] kicks off the build; later
/// calls reuse the cached SQLite handle.
final BundledPlaceIndex bundledPlaceIndex = BundledPlaceIndex();
