import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'mbtiles_tile_source.dart';

/// A tiny localhost HTTP server that streams vector tiles out of the imported
/// `.mbtiles` files plus the bundled glyph/sprite assets the offline style
/// needs for text labels and POI icons. MapLibre can only read URL sources,
/// so this is the bridge that lets it render the basemap fully offline.
///
/// Routes:
///   GET /tiles/{z}/{x}/{y}.pbf       → MBTiles hit, else proxied upstream
///   GET /fonts/{fontstack}/{range}.pbf → bundled Noto Sans glyph range
///   GET /sprite/{name}.{json,png}    → bundled Liberty sprite
///
/// Tile flow: try each registered MBTiles in order; on a miss try the
/// persistent disk cache, then the upstream tile provider (OpenFreeMap) so the
/// basemap covers the whole world when online while still serving downloaded
/// regions from disk. Upstream successes are written back to the disk cache.
/// Transient upstream failures are retried in-request and, if still failing,
/// return 503 so MapLibre re-asks on the next pan (never 204, which would
/// leave the tile permanently blank). Missing glyphs/sprite return 404.
class LocalTileServer {
  LocalTileServer({http.Client? upstreamClient, String? upstreamTileJsonUrl})
      : _upstream = upstreamClient ?? http.Client(),
        _upstreamTileJsonUrl = upstreamTileJsonUrl ?? _defaultTileJsonUrl;

  // OpenFreeMap publishes a TileJSON pointer at this URL; the document inside
  // contains the real `{z}/{x}/{y}.pbf` template, which embeds a dated planet
  // snapshot like `.../planet/20240611_001001_pt/...`. Resolve lazily on the
  // first cache miss so a bad network at startup doesn't break boot.
  static const String _defaultTileJsonUrl =
      'https://tiles.openfreemap.org/planet';
  static const String _upstreamUserAgent =
      'FalconView/1.0 (local tile proxy; contact: tarun@igismap.com)';
  // TileJSON resolve uses the high-zoom timeout (small JSON).
  static const Duration _upstreamTimeout = Duration(seconds: 10);

  /// Low-zoom tiles cover huge regions and are correspondingly big — a z0
  /// planet tile is often 2–5 MB while a z14 city block is 30–150 KB. On a
  /// slow link the same 10 s deadline that's fine for z12+ aborts every
  /// z0–6 fetch, leaving the basemap blank when the user zooms out. Give
  /// the low zooms a generous window so they actually complete.
  static Duration _tileTimeoutForZoom(int z) {
    if (z <= 3) return const Duration(seconds: 45);
    if (z <= 6) return const Duration(seconds: 25);
    if (z <= 9) return const Duration(seconds: 15);
    return const Duration(seconds: 10);
  }

  // LRU cap for proxied upstream tiles. 5000 × ~50 KB avg ≈ 250 MB — large
  // enough to hold every tile inside many full pan/zoom cycles around a
  // major city at z10-14. Disk-backed cache below catches anything that
  // overflows or survives across app restarts.
  static const int _upstreamCacheCapacity = 5000;

  /// Bundled MBTiles asset path. Lives in the app bundle, extracted to a
  /// writable location on first use because sqflite needs a real file path.
  static const String _bundledMbtilesAsset = 'assets/basemap/world.mbtiles';

  /// Persistent disk cache for proxied upstream tiles. Once a tile is
  /// successfully fetched from OpenFreeMap it lands here so future sessions
  /// (and pans MapLibre forgot about) serve it locally without ever hitting
  /// the network again. MBTiles schema so we can reuse [MbtilesTileSource]
  /// for reads if needed and inspect the file with standard tooling.
  static const String _diskCacheFileName = 'upstream_tile_cache.mbtiles';
  // Soft cap on tile count; we sample-evict the oldest 10% when exceeded so
  // we don't run a delete on every insert. 20k × 50 KB ≈ 1 GB ceiling.
  static const int _diskCacheCapacity = 20000;

  // A stored tile is only served if at least this fraction of its area lies
  // inside the source's real coverage. This is the fix for the "sparse tile
  // shadows upstream" bug: a source clipped to a small area (e.g. the bundled
  // Indore extract) still contains single z0–z6 tiles whose footprint spans a
  // continent but whose *data* is only the clipped sliver. Serving those would
  // paint one small region and leave the rest of the tile blank, because the
  // server would never fall through to the complete upstream tile. Requiring
  // majority coverage routes those giant low-zoom tiles to upstream while
  // still serving the fine-grained tiles that genuinely sit inside the region.
  static const double _tileCoverageThreshold = 0.5;

  HttpServer? _server;
  final List<MbtilesTileSource> _sources = <MbtilesTileSource>[];
  // Per-source coverage as [west, south, east, north] degrees, index-aligned
  // with [_sources]. Null entry → bounds unknown, so the source is queried
  // ungated (fail-open: better to serve a tile than wrongly withhold one).
  final List<List<double>?> _sourceBounds = <List<double>?>[];
  MbtilesTileSource? _bundledWorld;
  List<double>? _bundledWorldBounds;
  Future<MbtilesTileSource?>? _bundledWorldLoading;
  // Remember a failure so we don't retry rootBundle.load() on every tile miss
  // (12 MB asset = expensive to keep re-loading if it's somehow broken).
  bool _bundledWorldFailed = false;
  final http.Client _upstream;
  final String _upstreamTileJsonUrl;
  String? _resolvedUpstreamTileUrl;
  Future<String?>? _resolvingUpstream;

  // LRU cache of upstream tile responses (stored verbatim — usually gzipped —
  // so we can re-emit them with the original Content-Encoding without
  // re-compressing). Insertion order doubles as the eviction queue.
  final LinkedHashMap<String, Uint8List> _upstreamCache =
      LinkedHashMap<String, Uint8List>();

  // Dedup map: when MapLibre fires several concurrent requests for the same
  // tile during a pan/zoom, all callers await the same in-flight Future
  // instead of each opening its own network round-trip.
  final Map<String, Future<_UpstreamFetch>> _upstreamInflight =
      <String, Future<_UpstreamFetch>>{};

  // Asset bytes are cached after first read so MapLibre's flood of requests
  // for each glyph range (one per font × one per Unicode block × per zoom)
  // doesn't keep hitting rootBundle. Glyphs are ~100KB each; total ceiling
  // for our 6 files + 4 sprite files is well under 1 MB.
  final Map<String, Uint8List> _assetCache = <String, Uint8List>{};

  // Disk-backed persistent cache for proxied upstream tiles. Opened lazily on
  // the first upstream miss (writable sqlite — the FFI factory is initialised
  // in main()). Survives eviction from the in-memory LRU and app restarts, so
  // once an area has been viewed online it renders fully on every later run
  // without re-hitting the network.
  Database? _diskCache;
  Future<Database?>? _diskCacheOpening;
  bool _diskCacheFailed = false;
  // Count inserts so we only run the (relatively expensive) row-count + evict
  // sweep once every N writes instead of on every tile.
  int _diskWritesSinceEvict = 0;

  bool get isRunning => _server != null;

  /// Loopback URL template to drop into a style's vector source `tiles` array.
  String get tileUrlTemplate {
    final int port = _server?.port ?? 0;
    return 'http://127.0.0.1:$port/tiles/{z}/{x}/{y}.pbf';
  }

  /// URL template for the style's `glyphs` field. Fontstack names with spaces
  /// (e.g. "Noto Sans Regular") get percent-encoded by MapLibre when it
  /// substitutes — the handler decodes them before reading from assets.
  String get glyphsUrlTemplate {
    final int port = _server?.port ?? 0;
    return 'http://127.0.0.1:$port/fonts/{fontstack}/{range}.pbf';
  }

  /// Base URL for the style's `sprite` field (MapLibre appends .json/.png).
  String get spriteUrlBase {
    final int port = _server?.port ?? 0;
    return 'http://127.0.0.1:$port/sprite/liberty';
  }

  Future<int> start() async {
    if (_server != null) return _server!.port;
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle, onError: (Object e) {
      debugPrint('LocalTileServer listen error: $e');
    });
    debugPrint('LocalTileServer started on port ${server.port}');
    return server.port;
  }

  /// (Re)opens the set of MBTiles the server reads from. Closes the previous
  /// handles first. Call after an import so new regions become renderable.
  Future<void> setSources(List<String> paths) async {
    for (final MbtilesTileSource s in _sources) {
      await s.close();
    }
    _sources.clear();
    _sourceBounds.clear();
    for (final String path in paths) {
      try {
        final MbtilesTileSource src = await MbtilesTileSource.open(path);
        _sources.add(src);
        _sourceBounds.add(await src.boundsWsen());
      } catch (e) {
        debugPrint('LocalTileServer: failed to open $path: $e');
      }
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final HttpResponse res = req.response;
    try {
      if (req.method != 'GET') {
        res.statusCode = HttpStatus.methodNotAllowed;
        await res.close();
        return;
      }
      final List<String> seg = req.uri.pathSegments;
      if (seg.isEmpty) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      switch (seg.first) {
        case 'tiles':
          await _handleTile(seg, res);
          return;
        case 'fonts':
          await _handleFont(seg, res);
          return;
        case 'sprite':
          await _handleSprite(seg, res);
          return;
      }
      res.statusCode = HttpStatus.notFound;
      await res.close();
    } catch (e) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
      debugPrint('LocalTileServer handler error: $e');
    }
  }

  Future<void> _handleTile(List<String> seg, HttpResponse res) async {
    // Expect: tiles / z / x / y.pbf
    if (seg.length != 4) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final int? z = int.tryParse(seg[1]);
    final int? x = int.tryParse(seg[2]);
    final int? y = int.tryParse(seg[3].split('.').first);
    if (z == null || x == null || y == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    for (int i = 0; i < _sources.length; i++) {
      // Skip a source whose stored tile here would be a sparse sliver of the
      // real tile (see [_tileMostlyWithin]); fall through to the next source
      // or upstream so MapLibre gets the complete tile.
      if (!_tileMostlyWithin(_sourceBounds[i], z, x, y)) continue;
      final Uint8List? bytes = await _sources[i].rawTile(z, x, y);
      if (bytes == null || bytes.isEmpty) continue;
      await _emitTile(res, bytes);
      return;
    }

    // Bundled fallback — a low-zoom MBTiles shipped with the app so wide-area
    // panning works instantly with no network. Sits between user-imported
    // regions (which take precedence) and the upstream proxy. Gated the same
    // way: the bundle is clipped to a small area, so its giant low-zoom tiles
    // are withheld here and served complete from upstream instead.
    final MbtilesTileSource? bundle = await _ensureBundledWorld();
    if (bundle != null && _tileMostlyWithin(_bundledWorldBounds, z, x, y)) {
      final Uint8List? bytes = await bundle.rawTile(z, x, y);
      if (bytes != null && bytes.isNotEmpty) {
        await _emitTile(res, bytes);
        return;
      }
    }

    // MBTiles miss — try the upstream provider so the basemap covers tiles
    // outside any downloaded region when the user is online.
    //
    // A failed upstream MUST NOT return 204 here: MapLibre treats 204 as
    // "loaded but empty, never retry," so a single transient hiccup would
    // leave the tile permanently blank until the user invalidated the
    // source. Use 503 for transient errors so MapLibre re-requests on the
    // next pan/zoom (and 204 only when the response was genuinely "this
    // tile doesn't exist" — a 4xx from upstream).
    final _UpstreamFetch fetched = await _fetchUpstreamTile(z, x, y);
    if (fetched.bytes != null && fetched.bytes!.isNotEmpty) {
      final Uint8List body = fetched.bytes!;
      final bool gz =
          body.length >= 2 && body[0] == 0x1f && body[1] == 0x8b;
      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.contentTypeHeader, 'application/x-protobuf');
      if (gz) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      res.headers.set('Access-Control-Allow-Origin', '*');
      res.add(body);
      await res.close();
      return;
    }
    if (fetched.transient) {
      // Tells MapLibre "try me again on the next pan." Better than 204,
      // which would leave the tile permanently blank after one network blip.
      res.statusCode = HttpStatus.serviceUnavailable;
      res.headers.set('Access-Control-Allow-Origin', '*');
      await res.close();
      return;
    }

    // Genuine "no data here" (upstream said 4xx, or we have no upstream
    // configured at all). Mark loaded-but-empty so MapLibre stops asking.
    res.statusCode = HttpStatus.noContent;
    await res.close();
  }

  /// Streams a vector-tile body to MapLibre with the right headers, sniffing
  /// the gzip magic so we re-advertise the original Content-Encoding rather
  /// than re-compressing.
  Future<void> _emitTile(HttpResponse res, Uint8List bytes) async {
    final bool gz = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    res.statusCode = HttpStatus.ok;
    res.headers.set(HttpHeaders.contentTypeHeader, 'application/x-protobuf');
    if (gz) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.add(bytes);
    await res.close();
  }

  /// True if at least [_tileCoverageThreshold] of tile `(z,x,y)`'s area lies
  /// inside [boundsWsen] (`[west, south, east, north]` degrees). Used to decide
  /// whether a stored MBTiles tile is "complete enough" to serve, or whether we
  /// should fall through to upstream for the full tile.
  ///
  /// Fail-open: unknown bounds (null) → serve. A z3 tile that spans a whole
  /// continent but only overlaps a 1°-wide extract scores ~0 and is withheld;
  /// a z12 tile sitting inside a downloaded city scores ~1 and is served.
  bool _tileMostlyWithin(List<double>? boundsWsen, int z, int x, int y) {
    if (boundsWsen == null) return true;
    final double bw = boundsWsen[0];
    final double bs = boundsWsen[1];
    final double be = boundsWsen[2];
    final double bn = boundsWsen[3];
    final int n = 1 << z;
    final double tw = x / n * 360.0 - 180.0;
    final double te = (x + 1) / n * 360.0 - 180.0;
    final double tn = _tileLatDeg(y, n);
    final double ts = _tileLatDeg(y + 1, n);
    final double lonOverlap = math.min(te, be) - math.max(tw, bw);
    final double latOverlap = math.min(tn, bn) - math.max(ts, bs);
    if (lonOverlap <= 0 || latOverlap <= 0) return false;
    final double tileArea = (te - tw) * (tn - ts);
    if (tileArea <= 0) return true;
    return (lonOverlap * latOverlap) / tileArea >= _tileCoverageThreshold;
  }

  /// North edge latitude (degrees) of tile row `y` in a `n = 2^z` grid, via the
  /// inverse Web Mercator projection.
  static double _tileLatDeg(int y, int n) {
    final double m = math.pi * (1 - 2 * y / n);
    final double sinh = (math.exp(m) - math.exp(-m)) / 2;
    return math.atan(sinh) * 180.0 / math.pi;
  }

  /// Returns the bundled-world MBTiles handle, lazily extracting the asset
  /// to a writable path on first access (sqflite can only open from a file
  /// path, not from in-memory bytes). Subsequent callers either get the
  /// cached handle or piggy-back on the in-flight load. On failure, marks
  /// itself as failed so a 12 MB rootBundle.load isn't retried on every miss.
  Future<MbtilesTileSource?> _ensureBundledWorld() async {
    if (_bundledWorld != null) return _bundledWorld;
    if (_bundledWorldFailed) return null;
    final Future<MbtilesTileSource?>? inFlight = _bundledWorldLoading;
    if (inFlight != null) return inFlight;

    final Future<MbtilesTileSource?> work = _loadBundledWorld();
    _bundledWorldLoading = work;
    try {
      final MbtilesTileSource? result = await work;
      if (result == null) {
        _bundledWorldFailed = true;
      } else {
        _bundledWorld = result;
        _bundledWorldBounds = await result.boundsWsen();
      }
      return result;
    } finally {
      _bundledWorldLoading = null;
    }
  }

  Future<MbtilesTileSource?> _loadBundledWorld() async {
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final String dstPath = p.join(docs.path, 'bundled_world.mbtiles');
      final File dst = File(dstPath);
      if (!await dst.exists()) {
        final ByteData data = await rootBundle.load(_bundledMbtilesAsset);
        await dst.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        debugPrint('LocalTileServer: extracted bundled MBTiles → $dstPath');
      }
      return await MbtilesTileSource.open(dstPath);
    } catch (e) {
      debugPrint('LocalTileServer: bundled world.mbtiles unavailable: $e');
      return null;
    }
  }

  Future<_UpstreamFetch> _fetchUpstreamTile(int z, int x, int y) async {
    final String key = '$z/$x/$y';

    // Cache hit — bump to MRU and return immediately. This is what makes
    // pan/zoom feel instant after the first visit to an area.
    final Uint8List? cached = _upstreamCache.remove(key);
    if (cached != null) {
      _upstreamCache[key] = cached;
      return _UpstreamFetch.ok(cached);
    }

    // A concurrent caller is already fetching this tile — piggy-back on the
    // same Future so MapLibre's burst of identical requests during a pan
    // only triggers one network round-trip.
    final Future<_UpstreamFetch>? inFlight = _upstreamInflight[key];
    if (inFlight != null) return inFlight;

    final Future<_UpstreamFetch> work = _fetchFromDiskOrNetwork(z, x, y);
    _upstreamInflight[key] = work;
    try {
      final _UpstreamFetch result = await work;
      final Uint8List? bytes = result.bytes;
      if (bytes != null && bytes.isNotEmpty) {
        _upstreamCache[key] = bytes;
        while (_upstreamCache.length > _upstreamCacheCapacity) {
          _upstreamCache.remove(_upstreamCache.keys.first);
        }
      }
      return result;
    } finally {
      _upstreamInflight.remove(key);
    }
  }

  /// Disk cache sits between the in-memory LRU and the network: a tile fetched
  /// in any prior session (or one evicted from the small in-memory cache) is
  /// served straight from sqlite with no network round-trip. Network successes
  /// are written back so the area renders fully and instantly next time.
  Future<_UpstreamFetch> _fetchFromDiskOrNetwork(int z, int x, int y) async {
    final Uint8List? disk = await _diskCacheGet(z, x, y);
    if (disk != null && disk.isNotEmpty) {
      return _UpstreamFetch.ok(disk);
    }
    final _UpstreamFetch fetched = await _doFetchUpstreamTile(z, x, y);
    final Uint8List? bytes = fetched.bytes;
    if (bytes != null && bytes.isNotEmpty) {
      unawaited(_diskCachePut(z, x, y, bytes));
    }
    return fetched;
  }

  Future<_UpstreamFetch> _doFetchUpstreamTile(int z, int x, int y) async {
    final String? template = await _resolveUpstreamTileUrl();
    if (template == null) {
      // No upstream URL resolved — could be offline or TileJSON unreachable.
      // Treat as transient so a later pan retries once we have network.
      return const _UpstreamFetch.transient();
    }
    final String url = template
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');
    // Retry transient failures (timeout / 5xx / network blip) inside the
    // request rather than surfacing a 503. A 503 makes MapLibre mark the tile
    // errored and leave it BLANK until the user happens to pan it back into
    // view — that's the half-loaded map. Retrying here means a momentary
    // hiccup self-heals into a 200 the user never sees as a gap. Few, small
    // high-zoom tiles can afford 3 tries; the big low-zoom tiles get 2 so a
    // genuinely dead link doesn't stall the whole viewport for minutes.
    final int maxAttempts = z >= 10 ? 3 : 2;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final http.Response r = await _upstream
            .get(Uri.parse(url), headers: <String, String>{
              'User-Agent': _upstreamUserAgent,
            })
            .timeout(_tileTimeoutForZoom(z));
        if (r.statusCode == 200) {
          return _UpstreamFetch.ok(r.bodyBytes);
        }
        // 4xx from upstream → genuinely no tile here (out-of-range zoom,
        // ocean tile, etc.). Tell MapLibre to stop asking (204 path). No
        // point retrying — it'll stay 4xx.
        if (r.statusCode >= 400 && r.statusCode < 500) {
          return const _UpstreamFetch.notFound();
        }
        // 5xx or anything else unexpected → fall through to retry.
      } catch (_) {
        // Network error, timeout, DNS failure — fall through to retry.
      }
      if (attempt < maxAttempts) {
        // Linear backoff (300ms, 600ms…) — long enough to ride out a blip,
        // short enough that the tile still fills promptly.
        await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
    // Exhausted retries → transient, so MapLibre re-requests on the next pan
    // as a last resort (and the disk cache means a later success sticks).
    return const _UpstreamFetch.transient();
  }

  // ---------------- Disk-backed tile cache ----------------

  /// Returns the writable sqlite cache handle, opening it (and creating the
  /// `tiles` table) on first use. Single in-flight open shared by concurrent
  /// callers; on failure marks itself failed so we don't retry the open on
  /// every tile miss.
  Future<Database?> _ensureDiskCache() async {
    if (_diskCache != null) return _diskCache;
    if (_diskCacheFailed) return null;
    final Future<Database?>? inFlight = _diskCacheOpening;
    if (inFlight != null) return inFlight;
    final Future<Database?> work = _openDiskCache();
    _diskCacheOpening = work;
    try {
      final Database? db = await work;
      if (db == null) {
        _diskCacheFailed = true;
      } else {
        _diskCache = db;
      }
      return db;
    } finally {
      _diskCacheOpening = null;
    }
  }

  Future<Database?> _openDiskCache() async {
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final String path = p.join(docs.path, _diskCacheFileName);
      final Database db = await openDatabase(path);
      // Stored in plain XYZ (not TMS) since this is our own cache. fetched_at
      // is an insertion counter used purely for LRU-ish eviction ordering.
      await db.execute(
        'CREATE TABLE IF NOT EXISTS tiles ('
        'zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, '
        'tile_data BLOB, fetched_at INTEGER, '
        'PRIMARY KEY (zoom_level, tile_column, tile_row))',
      );
      debugPrint('LocalTileServer: disk tile cache ready → $path');
      return db;
    } catch (e) {
      debugPrint('LocalTileServer: disk cache unavailable: $e');
      return null;
    }
  }

  Future<Uint8List?> _diskCacheGet(int z, int x, int y) async {
    final Database? db = await _ensureDiskCache();
    if (db == null) return null;
    try {
      final List<Map<String, Object?>> rows = await db.query(
        'tiles',
        columns: <String>['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: <Object?>[z, x, y],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final Object? data = rows.first['tile_data'];
      if (data is Uint8List) return data;
      if (data is List<int>) return Uint8List.fromList(data);
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _diskCachePut(int z, int x, int y, Uint8List bytes) async {
    final Database? db = await _ensureDiskCache();
    if (db == null) return;
    try {
      await db.insert(
        'tiles',
        <String, Object?>{
          'zoom_level': z,
          'tile_column': x,
          'tile_row': y,
          'tile_data': bytes,
          'fetched_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (++_diskWritesSinceEvict >= 500) {
        _diskWritesSinceEvict = 0;
        unawaited(_evictDiskCacheIfNeeded(db));
      }
    } catch (_) {
      // A write failure just means this tile isn't persisted — it's still
      // served from the in-memory cache this session.
    }
  }

  /// Trims the oldest tiles when the cache grows past its soft cap. Sweeps the
  /// excess plus another 10% so we don't run a delete on every insert once the
  /// ceiling is reached.
  Future<void> _evictDiskCacheIfNeeded(Database db) async {
    try {
      final List<Map<String, Object?>> r =
          await db.rawQuery('SELECT COUNT(*) AS c FROM tiles');
      final Object? c = r.isEmpty ? null : r.first['c'];
      final int count = c is num ? c.toInt() : 0;
      if (count <= _diskCacheCapacity) return;
      final int toDelete =
          (count - _diskCacheCapacity) + (_diskCacheCapacity * 0.1).round();
      await db.rawDelete(
        'DELETE FROM tiles WHERE rowid IN '
        '(SELECT rowid FROM tiles ORDER BY fetched_at ASC LIMIT ?)',
        <Object?>[toDelete],
      );
    } catch (_) {}
  }

  /// Resolves the upstream `{z}/{x}/{y}` template from the TileJSON pointer.
  /// OpenFreeMap embeds a dated planet snapshot (e.g. `.../planet/20240611_..`)
  /// inside the TileJSON's `tiles[0]` field, so we can't hardcode the path.
  /// Single in-flight resolution shared by all concurrent callers; cached
  /// permanently on success, null-returned-but-not-cached on failure so the
  /// next tile request retries (handles "started offline → went online").
  Future<String?> _resolveUpstreamTileUrl() async {
    final String? cached = _resolvedUpstreamTileUrl;
    if (cached != null) return cached;
    final Future<String?>? inFlight = _resolvingUpstream;
    if (inFlight != null) return inFlight;
    final Future<String?> work = _doResolveUpstreamTileUrl();
    _resolvingUpstream = work;
    try {
      final String? result = await work;
      if (result != null) _resolvedUpstreamTileUrl = result;
      return result;
    } finally {
      _resolvingUpstream = null;
    }
  }

  Future<String?> _doResolveUpstreamTileUrl() async {
    try {
      final http.Response r = await _upstream
          .get(Uri.parse(_upstreamTileJsonUrl), headers: <String, String>{
            'User-Agent': _upstreamUserAgent,
          })
          .timeout(_upstreamTimeout);
      if (r.statusCode != 200) {
        debugPrint(
          'LocalTileServer: TileJSON $_upstreamTileJsonUrl returned ${r.statusCode}',
        );
        return null;
      }
      final dynamic decoded = jsonDecode(r.body);
      if (decoded is! Map) return null;
      final dynamic tilesField = decoded['tiles'];
      if (tilesField is! List || tilesField.isEmpty) return null;
      final dynamic first = tilesField.first;
      if (first is! String) return null;
      debugPrint('LocalTileServer: resolved upstream tiles → $first');
      return first;
    } catch (e) {
      debugPrint('LocalTileServer: TileJSON resolve failed: $e');
      return null;
    }
  }

  Future<void> _handleFont(List<String> seg, HttpResponse res) async {
    // Expect: fonts / {fontstack} / {range}.pbf  (path segments are already
    // percent-decoded by HttpRequest.uri.pathSegments)
    if (seg.length != 3) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final String fontstack = seg[1];
    final String rangeFile = seg[2];
    if (!rangeFile.endsWith('.pbf')) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final String assetPath = 'assets/glyphs/$fontstack/$rangeFile';
    final Uint8List? bytes = await _loadAsset(assetPath);
    if (bytes == null) {
      // Missing range — MapLibre tolerates 404 and skips text in that range.
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.statusCode = HttpStatus.ok;
    res.headers.set(HttpHeaders.contentTypeHeader, 'application/x-protobuf');
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.add(bytes);
    await res.close();
  }

  Future<void> _handleSprite(List<String> seg, HttpResponse res) async {
    // Expect: sprite / liberty.json | liberty.png | liberty@2x.json | etc.
    if (seg.length != 2) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final String file = seg[1];
    final String assetPath = 'assets/sprite/$file';
    final Uint8List? bytes = await _loadAsset(assetPath);
    if (bytes == null) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    final String contentType =
        file.endsWith('.json') ? 'application/json' : 'image/png';
    res.statusCode = HttpStatus.ok;
    res.headers.set(HttpHeaders.contentTypeHeader, contentType);
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.add(bytes);
    await res.close();
  }

  Future<Uint8List?> _loadAsset(String path) async {
    final Uint8List? cached = _assetCache[path];
    if (cached != null) return cached;
    try {
      final ByteData data = await rootBundle.load(path);
      final Uint8List bytes = data.buffer.asUint8List(
        data.offsetInBytes, data.lengthInBytes);
      _assetCache[path] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    for (final MbtilesTileSource s in _sources) {
      await s.close();
    }
    _sources.clear();
    _sourceBounds.clear();
    if (_bundledWorld != null) {
      try {
        await _bundledWorld!.close();
      } catch (_) {}
      _bundledWorld = null;
      _bundledWorldBounds = null;
    }
    _upstreamCache.clear();
    _upstreamInflight.clear();
    if (_diskCache != null) {
      try {
        await _diskCache!.close();
      } catch (_) {}
      _diskCache = null;
    }
    _upstream.close();
  }
}

/// Outcome of an upstream tile fetch. Distinguishes "tile bytes are here",
/// "upstream says 4xx, this tile genuinely doesn't exist" (route to 204), and
/// "transient failure — try me again on the next pan" (route to 503). Crucial
/// because MapLibre treats 204 as a permanent loaded-empty state and would
/// never re-request a tile that hit one network blip otherwise.
class _UpstreamFetch {
  final Uint8List? bytes;
  final bool transient;
  const _UpstreamFetch.ok(this.bytes) : transient = false;
  const _UpstreamFetch.notFound()
      : bytes = null,
        transient = false;
  const _UpstreamFetch.transient()
      : bytes = null,
        transient = true;
}