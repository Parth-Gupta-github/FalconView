import 'dart:io';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

/// Writes vector tiles into a standard **MBTiles** (SQLite) file.
///
/// Used on desktop (macOS/Windows/Linux) to materialise a downloaded offline
/// region the webview map can render through [LocalTileServer]. maplibre_gl's
/// native `downloadOfflineRegion` has no desktop binding, so instead of relying
/// on its private tile cache we fetch the region's tiles ourselves and store
/// them here — the same `.mbtiles` shape the importer already consumes, so the
/// downloaded region behaves exactly like an imported one (renders, searches,
/// routes offline).
///
/// MBTiles stores rows bottom-up (TMS); [put] flips XYZ `y` → TMS on write so
/// `MbtilesTileSource` / `LocalTileServer` can read it back with their usual
/// `(2^z - 1) - y` flip.
class MbtilesWriter {
  MbtilesWriter._(this._db);

  final Database _db;
  Batch? _batch;
  int _pending = 0;

  // Commit in chunks so a large region doesn't hold one giant transaction.
  static const int _flushEvery = 400;

  /// Creates a fresh `.mbtiles` at [path] (overwriting any existing file) with
  /// the standard `metadata` + `tiles` schema and the required metadata rows.
  static Future<MbtilesWriter> create(
    String path, {
    required String name,
    required String bounds, // "minLon,minLat,maxLon,maxLat"
    required int minZoom,
    required int maxZoom,
  }) async {
    final File f = File(path);
    if (await f.exists()) await f.delete();

    final Database db = await openDatabase(
      path,
      version: 1,
      onCreate: (Database db, int _) async {
        await db.execute(
          'CREATE TABLE metadata (name TEXT, value TEXT)',
        );
        await db.execute(
          'CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, '
          'tile_row INTEGER, tile_data BLOB)',
        );
        await db.execute(
          'CREATE UNIQUE INDEX tile_index ON '
          'tiles (zoom_level, tile_column, tile_row)',
        );
      },
    );

    final Batch meta = db.batch();
    void put(String k, String v) =>
        meta.insert('metadata', <String, Object?>{'name': k, 'value': v});
    put('name', name);
    put('format', 'pbf');
    put('bounds', bounds);
    put('minzoom', '$minZoom');
    put('maxzoom', '$maxZoom');
    put('type', 'overlay');
    put('version', '1.0');
    await meta.commit(noResult: true);

    return MbtilesWriter._(db);
  }

  /// Stores one tile. [bytes] are written verbatim — pass them in whatever
  /// encoding the server should hand back (uncompressed MVT is fine; the
  /// reader sniffs the gzip magic bytes).
  Future<void> put(int z, int x, int y, Uint8List bytes) async {
    final int tmsRow = ((1 << z) - 1) - y; // XYZ y -> TMS tile_row
    final Batch b = _batch ??= _db.batch();
    b.insert(
      'tiles',
      <String, Object?>{
        'zoom_level': z,
        'tile_column': x,
        'tile_row': tmsRow,
        'tile_data': bytes,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    if (++_pending >= _flushEvery) await flush();
  }

  Future<void> flush() async {
    final Batch? b = _batch;
    if (b == null || _pending == 0) return;
    await b.commit(noResult: true);
    _batch = null;
    _pending = 0;
  }

  Future<void> close() async {
    await flush();
    await _db.close();
  }
}
