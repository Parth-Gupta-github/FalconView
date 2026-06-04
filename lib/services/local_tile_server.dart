import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'mbtiles_tile_source.dart';

/// A tiny localhost HTTP server that streams vector tiles out of the imported
/// `.mbtiles` files plus the bundled glyph/sprite assets the offline style
/// needs for text labels and POI icons. MapLibre can only read URL sources,
/// so this is the bridge that lets it render the basemap fully offline.
///
/// Routes:
///   GET /tiles/{z}/{x}/{y}.pbf       → next-hit MBTiles lookup
///   GET /fonts/{fontstack}/{range}.pbf → bundled Noto Sans glyph range
///   GET /sprite/{name}.{json,png}    → bundled Liberty sprite
///
/// Tiles missing from every region return 204 (MapLibre treats as empty).
/// Missing glyphs/sprite return 404 (MapLibre falls back gracefully).
class LocalTileServer {
  HttpServer? _server;
  final List<MbtilesTileSource> _sources = <MbtilesTileSource>[];

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
    // No region has this tile — empty, not an error.
    res.statusCode = HttpStatus.noContent;
    await res.close();
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
  }
}