import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Serves vector tiles from a bundled MBTiles asset over a tiny localhost
/// HTTP server, so MapLibre can render a fallback basemap fully offline when
/// no region has been downloaded yet.
///
/// Lifecycle:
///   - First call to [ensureStarted] copies the asset to writable storage
///     (sqflite can't open from `rootBundle`) and boots an `HttpServer` bound
///     to 127.0.0.1 on an OS-picked port.
///   - [tileTemplateUrl] returns the URL template you splice into the style.
///   - [stop] tears it down.
///
/// If the asset is missing (developer hasn't run `tools/planetiler/generate`),
/// [ensureStarted] silently no-ops and [tileTemplateUrl] stays null. Callers
/// must treat null as "no offline fallback available" and fall back to the
/// upstream style URL.
class BundledBasemapServer {
  BundledBasemapServer({this.assetPath = 'assets/basemap/world.mbtiles'});

  final String assetPath;
  static const String _localFileName = 'bundled_basemap.mbtiles';

  HttpServer? _server;
  Database? _db;
  String? _tileTemplate;
  Future<void>? _startInFlight;

  bool get isRunning => _server != null && _db != null;

  /// `http://127.0.0.1:<port>/{z}/{x}/{y}.pbf` once started; null otherwise.
  String? get tileTemplateUrl => _tileTemplate;

  /// Idempotent + concurrency-safe: parallel callers share the same start.
  Future<void> ensureStarted() async {
    if (isRunning) return;
    final Future<void>? inFlight = _startInFlight;
    if (inFlight != null) return inFlight;
    final Completer<void> c = Completer<void>();
    _startInFlight = c.future;
    try {
      await _start();
      c.complete();
    } catch (e, s) {
      debugPrint('BundledBasemapServer failed to start: $e\n$s');
      c.complete(); // Don't surface — callers handle null tileTemplateUrl.
    } finally {
      _startInFlight = null;
    }
  }

  Future<void> _start() async {
    if (kIsWeb) return;
    final File? mb = await _materializeAsset();
    if (mb == null) return; // Asset missing — leave server unstarted.
    // singleInstance:false isolates our handle so other services that also
    // open the same MBTiles file (e.g. BundledPlaceIndex) can close their
    // connection without invalidating ours. With the default true, sqflite
    // shares one cached handle per path and any close kills it for everyone.
    _db = await openDatabase(
      mb.path,
      readOnly: true,
      singleInstance: false,
    );
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _tileTemplate = 'http://127.0.0.1:${server.port}/{z}/{x}/{y}.pbf';
    // Fire and forget — handler errors are caught per-request below.
    server.listen(_handleRequest, onError: (Object e, StackTrace s) {
      debugPrint('BundledBasemapServer listen error: $e');
    });
  }

  Future<File?> _materializeAsset() async {
    try {
      final Directory docs = await getApplicationDocumentsDirectory();
      final File dest = File(p.join(docs.path, _localFileName));
      if (await dest.exists() && (await dest.length()) > 0) return dest;
      final ByteData bd = await rootBundle.load(assetPath);
      await dest.writeAsBytes(
        bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
        flush: true,
      );
      return dest;
    } catch (e) {
      // Either the asset isn't bundled (developer hasn't run Planetiler) or
      // writable storage is unavailable. Either way, no fallback.
      debugPrint('BundledBasemapServer: asset unavailable ($e)');
      return null;
    }
  }

  static final RegExp _tilePathRegex =
      RegExp(r'^/(\d+)/(\d+)/(\d+)\.(?:pbf|mvt)$');

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      if (req.method != 'GET' && req.method != 'HEAD') {
        await _respond(req, HttpStatus.methodNotAllowed);
        return;
      }
      final RegExpMatch? m = _tilePathRegex.firstMatch(req.uri.path);
      if (m == null) {
        await _respond(req, HttpStatus.notFound);
        return;
      }
      final int z = int.parse(m.group(1)!);
      final int x = int.parse(m.group(2)!);
      final int y = int.parse(m.group(3)!);
      // MBTiles spec uses TMS scheme — flip Y from XYZ to TMS.
      final int tmsY = ((1 << z) - 1) - y;

      final Database? db = _db;
      if (db == null) {
        await _respond(req, HttpStatus.serviceUnavailable);
        return;
      }
      final List<Map<String, Object?>> rows = await db.query(
        'tiles',
        columns: <String>['tile_data'],
        where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
        whereArgs: <Object?>[z, x, tmsY],
        limit: 1,
      );
      if (rows.isEmpty) {
        // 204 (vs 404) so MapLibre treats it as "empty tile" and doesn't retry.
        await _respond(req, HttpStatus.noContent);
        return;
      }
      final Uint8List bytes = rows.first['tile_data']! as Uint8List;
      final bool isGzip =
          bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
      req.response
        ..statusCode = HttpStatus.ok
        ..headers.set('Content-Type', 'application/x-protobuf')
        ..headers.set('Cache-Control', 'public, max-age=86400')
        ..headers.set('Access-Control-Allow-Origin', '*');
      if (isGzip) req.response.headers.set('Content-Encoding', 'gzip');
      if (req.method == 'GET') req.response.add(bytes);
      await req.response.close();
    } catch (e, s) {
      debugPrint('BundledBasemapServer handler error: $e\n$s');
      try {
        await _respond(req, HttpStatus.internalServerError);
      } catch (_) {}
    }
  }

  Future<void> _respond(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }

  Future<void> stop() async {
    final HttpServer? s = _server;
    _server = null;
    _tileTemplate = null;
    if (s != null) await s.close(force: true);
    final Database? db = _db;
    _db = null;
    if (db != null) await db.close();
  }

  /// Reads the MBTiles `metadata` table. Useful for surfacing version /
  /// bounds info in diagnostics. Returns empty map if unavailable.
  Future<Map<String, String>> metadata() async {
    final Database? db = _db;
    if (db == null) return const <String, String>{};
    try {
      final List<Map<String, Object?>> rows =
          await db.query('metadata', columns: <String>['name', 'value']);
      return <String, String>{
        for (final Map<String, Object?> r in rows)
          (r['name'] as String): (r['value'] as String? ?? ''),
      };
    } catch (_) {
      return const <String, String>{};
    }
  }
}

/// App-wide singleton. Initialised lazily on first use.
final BundledBasemapServer bundledBasemapServer = BundledBasemapServer();

/// Loads the offline fallback style JSON from assets, splices the runtime
/// tile-server URL template into it, and returns the rewritten JSON string
/// ready for `MapLibreMap.styleString`.
///
/// Returns null if the server isn't running (asset missing). Callers should
/// fall back to their normal online style in that case.
Future<String?> loadOfflineRenderStyle({
  String stylePath = 'assets/styles/falconview_offline.json',
}) async {
  await bundledBasemapServer.ensureStarted();
  final String? tpl = bundledBasemapServer.tileTemplateUrl;
  if (tpl == null) return null;
  try {
    final String raw = await rootBundle.loadString(stylePath);
    final Map<String, dynamic> style =
        jsonDecode(raw) as Map<String, dynamic>;
    // Patch every vector source's `tiles` array with our runtime URL.
    final Map<String, dynamic>? sources =
        (style['sources'] as Map?)?.cast<String, dynamic>();
    if (sources != null) {
      for (final MapEntry<String, dynamic> e in sources.entries) {
        final Map<String, dynamic>? src =
            (e.value as Map?)?.cast<String, dynamic>();
        if (src == null) continue;
        if (src['type'] == 'vector') {
          src['tiles'] = <String>[tpl];
          // Remove TileJSON pointer so MapLibre doesn't try to fetch it.
          src.remove('url');
        }
      }
    }
    return jsonEncode(style);
  } catch (e) {
    debugPrint('loadOfflineRenderStyle failed: $e');
    return null;
  }
}
