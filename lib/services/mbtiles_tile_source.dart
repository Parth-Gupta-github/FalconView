import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:sqflite/sqflite.dart';

import '../util/tile_math.dart';

/// One vector tile read out of an `.mbtiles` file, converted to XYZ `y` and
/// ungzipped — ready for the MVT decoders during graph/POI building.
class MbtilesTile {
  const MbtilesTile(this.x, this.y, this.bytes);
  final int x;
  final int y;
  final Uint8List bytes;
}

/// Reads vector tiles from an MBTiles file (a SQLite container of `z/x/y` MVT
/// blobs). Two roles:
///   * **serving** — [rawTile] returns the stored bytes verbatim (still
///     gzipped) so the local tile server can stream them straight to MapLibre.
///   * **building** — [tilePage]/[tileCount] feed the POI + road-graph
///     extraction, ungzipping as they go.
///
/// MBTiles quirks handled here: rows are stored bottom-up (TMS) so we flip to
/// XYZ `y`, and tiles are usually gzipped.
class MbtilesTileSource {
  MbtilesTileSource._(this._db);

  final Database _db;

  static Future<MbtilesTileSource> open(String path) async {
    final Database db = await openReadOnlyDatabase(path);
    return MbtilesTileSource._(db);
  }

  Future<void> close() => _db.close();

  // ---------------- Serving ----------------

  /// Stored tile bytes for an XYZ `(z,x,y)`, untouched (caller decides whether
  /// to set `Content-Encoding: gzip` by sniffing the magic bytes). Null if the
  /// tile isn't in this file.
  Future<Uint8List?> rawTile(int z, int x, int y) async {
    final int tmsRow = ((1 << z) - 1) - y;
    final List<Map<String, Object?>> rows = await _db.query(
      'tiles',
      columns: <String>['tile_data'],
      where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
      whereArgs: <Object?>[z, x, tmsRow],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final Object? data = rows.first['tile_data'];
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    return null;
  }

  // ---------------- Building ----------------

  Future<int> tileCount(int zMin, int zMax) async {
    final List<Map<String, Object?>> r = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM tiles WHERE zoom_level BETWEEN ? AND ?',
      <Object?>[zMin, zMax],
    );
    final Object? c = r.isEmpty ? null : r.first['c'];
    return c is num ? c.toInt() : 0;
  }

  /// A page of tiles at one zoom level, XYZ-`y` and ungzipped. Stable `rowid`
  /// ordering keeps paging consistent.
  Future<List<MbtilesTile>> tilePage(int z, int limit, int offset) async {
    final List<Map<String, Object?>> rows = await _db.query(
      'tiles',
      columns: <String>['tile_column', 'tile_row', 'tile_data'],
      where: 'zoom_level = ?',
      whereArgs: <Object?>[z],
      orderBy: 'rowid',
      limit: limit,
      offset: offset,
    );
    final List<MbtilesTile> out = <MbtilesTile>[];
    final int n = 1 << z;
    for (final Map<String, Object?> r in rows) {
      final Object? colAny = r['tile_column'];
      final Object? rowAny = r['tile_row'];
      if (colAny is! num || rowAny is! num) continue;
      final int x = colAny.toInt();
      final int y = (n - 1) - rowAny.toInt();
      final Uint8List? bytes = _inflate(r['tile_data']);
      if (bytes == null) continue;
      out.add(MbtilesTile(x, y, bytes));
    }
    return out;
  }

  Uint8List? _inflate(Object? data) {
    Uint8List bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List<int>) {
      bytes = Uint8List.fromList(data);
    } else {
      return null;
    }
    if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      return Uint8List.fromList(const GZipDecoder().decodeBytes(bytes));
    }
    return bytes;
  }

  // ---------------- Metadata ----------------

  Future<Map<String, String>> metadata() async {
    try {
      final List<Map<String, Object?>> rows =
          await _db.query('metadata', columns: <String>['name', 'value']);
      final Map<String, String> out = <String, String>{};
      for (final Map<String, Object?> r in rows) {
        final Object? k = r['name'];
        final Object? v = r['value'];
        if (k is String && v != null) out[k] = '$v';
      }
      return out;
    } catch (_) {
      return <String, String>{};
    }
  }

  /// Min/max zoom present, from metadata if available else the tiles table.
  Future<(int, int)?> zoomRange() async {
    final Map<String, String> meta = await metadata();
    final int? metaMin = int.tryParse(meta['minzoom'] ?? '');
    final int? metaMax = int.tryParse(meta['maxzoom'] ?? '');
    if (metaMin != null && metaMax != null) return (metaMin, metaMax);
    final List<Map<String, Object?>> r = await _db.rawQuery(
      'SELECT MIN(zoom_level) AS lo, MAX(zoom_level) AS hi FROM tiles',
    );
    final Object? lo = r.isEmpty ? null : r.first['lo'];
    final Object? hi = r.isEmpty ? null : r.first['hi'];
    if (lo is num && hi is num) return (lo.toInt(), hi.toInt());
    return null;
  }

  /// Geographic extent as `[west, south, east, north]` degrees (or null if
  /// unknown). A maplibre-free wrapper over [bounds] for callers — like the
  /// local tile server — that only need the raw numbers and shouldn't pull in
  /// the maplibre types.
  Future<List<double>?> boundsWsen() async {
    final LatLngBounds? b = await bounds();
    if (b == null) return null;
    return <double>[
      b.southwest.longitude,
      b.southwest.latitude,
      b.northeast.longitude,
      b.northeast.latitude,
    ];
  }

  /// Geographic extent — prefers the `bounds` metadata
  /// ("west,south,east,north"), else derives from the tile range at max zoom.
  Future<LatLngBounds?> bounds() async {
    final Map<String, String> meta = await metadata();
    final LatLngBounds? fromMeta = _parseBounds(meta['bounds']);
    if (fromMeta != null) return fromMeta;
    return _deriveBoundsFromTiles();
  }

  LatLngBounds? _parseBounds(String? raw) {
    if (raw == null) return null;
    final List<String> parts = raw.split(',');
    if (parts.length != 4) return null;
    final double? west = double.tryParse(parts[0].trim());
    final double? south = double.tryParse(parts[1].trim());
    final double? east = double.tryParse(parts[2].trim());
    final double? north = double.tryParse(parts[3].trim());
    if (west == null || south == null || east == null || north == null) {
      return null;
    }
    return LatLngBounds(
      southwest: LatLng(south, west),
      northeast: LatLng(north, east),
    );
  }

  Future<LatLngBounds?> _deriveBoundsFromTiles() async {
    final List<Map<String, Object?>> zr =
        await _db.rawQuery('SELECT MAX(zoom_level) AS z FROM tiles');
    final Object? zAny = zr.isEmpty ? null : zr.first['z'];
    if (zAny is! num) return null;
    final int z = zAny.toInt();
    final List<Map<String, Object?>> r = await _db.rawQuery(
      'SELECT MIN(tile_column) AS minx, MAX(tile_column) AS maxx, '
      'MIN(tile_row) AS miny, MAX(tile_row) AS maxy '
      'FROM tiles WHERE zoom_level = ?',
      <Object?>[z],
    );
    if (r.isEmpty) return null;
    final Map<String, Object?> row = r.first;
    final Object? minx = row['minx'];
    final Object? maxx = row['maxx'];
    final Object? minyTms = row['miny'];
    final Object? maxyTms = row['maxy'];
    if (minx is! num || maxx is! num || minyTms is! num || maxyTms is! num) {
      return null;
    }
    final int n = 1 << z;
    final int yNorth = (n - 1) - maxyTms.toInt();
    final int ySouth = (n - 1) - minyTms.toInt();
    const int extent = 4096;
    final List<double> nw =
        TileMath.tilePixelToLatLng(z, minx.toInt(), yNorth, 0, 0, extent);
    final List<double> se =
        TileMath.tilePixelToLatLng(z, maxx.toInt(), ySouth, extent, extent, extent);
    return LatLngBounds(
      southwest: LatLng(se[0], nw[1]),
      northeast: LatLng(nw[0], se[1]),
    );
  }
}
