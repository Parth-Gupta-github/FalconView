import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

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
/// upstream tile provider (OpenFreeMap) so the basemap covers the whole
/// world when online while still serving downloaded regions from disk.
/// Network failure or no internet → 204 (MapLibre renders an empty tile).
/// Missing glyphs/sprite return 404 (MapLibre falls back gracefully).
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
  static const Duration _upstreamTimeout = Duration(seconds: 10);

  // LRU cap for proxied upstream tiles. ~500 tiles × ~50 KB avg ≈ 25 MB —
  // enough to cover a few full pan/zoom cycles around any city without
  // re-fetching, far below what we'd worry about on a desktop process.
  static const int _upstreamCacheCapacity = 500;

  HttpServer? _server;
  final List<MbtilesTileSource> _sources = <MbtilesTileSource>[];
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
    for (final String path in paths) {
      try {
        _sources.add(await MbtilesTileSource.open(path));
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
    for (final MbtilesTileSource src in _sources) {
      final Uint8List? bytes = await src.rawTile(z, x, y);
      if (bytes == null || bytes.isEmpty) continue;
      final bool gz =
          bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.contentTypeHeader, 'application/x-protobuf');
      if (gz) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
      res.headers.set('Access-Control-Allow-Origin', '*');
      res.add(bytes);
      await res.close();
      return;
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

    final Future<_UpstreamFetch> work = _doFetchUpstreamTile(z, x, y);
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
    try {
      final http.Response r = await _upstream
          .get(Uri.parse(url), headers: <String, String>{
            'User-Agent': _upstreamUserAgent,
          })
          .timeout(_upstreamTimeout);
      if (r.statusCode == 200) {
        return _UpstreamFetch.ok(r.bodyBytes);
      }
      // 4xx from upstream → genuinely no tile here (out-of-range zoom,
      // ocean tile, etc.). Tell MapLibre to stop asking (204 path).
      if (r.statusCode >= 400 && r.statusCode < 500) {
        return const _UpstreamFetch.notFound();
      }
      // 5xx or anything else unexpected → transient, retry on next pan.
      return const _UpstreamFetch.transient();
    } catch (_) {
      // Network error, timeout, DNS failure — all transient.
      return const _UpstreamFetch.transient();
    }
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
    _upstreamCache.clear();
    _upstreamInflight.clear();
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