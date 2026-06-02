import 'dart:io';

import 'package:flutter/foundation.dart';

import 'mbtiles_tile_source.dart';

/// A tiny localhost HTTP server that streams vector tiles out of the imported
/// `.mbtiles` files. MapLibre can only read a *URL* tile source, so this is the
/// bridge that lets it render the basemap from local files with no network.
///
/// Serves `GET /tiles/{z}/{x}/{y}.pbf` by checking each registered MBTiles in
/// turn and returning the first hit (bytes verbatim, with `Content-Encoding:
/// gzip` when the stored blob is gzipped). Missing tiles return 204 so MapLibre
/// treats them as empty rather than an error.
class LocalTileServer {
  HttpServer? _server;
  final List<MbtilesTileSource> _sources = <MbtilesTileSource>[];

  bool get isRunning => _server != null;

  /// Loopback URL template to drop into a style's vector source `tiles` array.
  String get tileUrlTemplate {
    final int port = _server?.port ?? 0;
    return 'http://127.0.0.1:$port/tiles/{z}/{x}/{y}.pbf';
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
      final List<String> seg = req.uri.pathSegments;
      // Expect: tiles / z / x / y.pbf
      if (req.method == 'GET' && seg.length == 4 && seg[0] == 'tiles') {
        final int? z = int.tryParse(seg[1]);
        final int? x = int.tryParse(seg[2]);
        final int? y = int.tryParse(seg[3].split('.').first);
        if (z != null && x != null && y != null) {
          for (final MbtilesTileSource src in _sources) {
            final Uint8List? bytes = await src.rawTile(z, x, y);
            if (bytes == null || bytes.isEmpty) continue;
            final bool gz =
                bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
            res.statusCode = HttpStatus.ok;
            res.headers.set(HttpHeaders.contentTypeHeader,
                'application/x-protobuf');
            if (gz) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
            res.headers.set('Access-Control-Allow-Origin', '*');
            res.add(bytes);
            await res.close();
            return;
          }
          // No region has this tile — empty, not an error.
          res.statusCode = HttpStatus.noContent;
          await res.close();
          return;
        }
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

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    for (final MbtilesTileSource s in _sources) {
      await s.close();
    }
    _sources.clear();
  }
}