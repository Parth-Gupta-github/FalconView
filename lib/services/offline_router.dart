import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:vector_tile/vector_tile.dart';

import '../models/place.dart';
import '../util/tile_math.dart';
import 'routing_service.dart' show RouteResult;

class OfflineRoutingException implements Exception {
  OfflineRoutingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Builds a per-region offline road graph by decoding the `transportation`
/// layer from MVT vector tiles (same source as the POI index). Stores nodes
/// and directed edges in the same per-region SQLite file alongside POIs.
///
/// Routing uses Dijkstra over the on-disk graph at query time.
class OfflineRouter {
  OfflineRouter({
    http.Client? client,
    this._styleUrl = _defaultStyle,
  }) : _client = client ?? http.Client();

  static const String _defaultStyle =
      'https://tiles.openfreemap.org/styles/liberty';
  static const String _userAgent =
      'FalconView/1.0 (offline router; contact: tarun@igismap.com)';
  static const String _dir = 'region_indexes';

  // Roads only exist in tiles at zoom 14 with full detail; lower zooms only
  // include motorway/trunk/primary. Use z14 for graph completeness.
  static const int _zMin = 13;
  static const int _zMax = 14;

  static const Duration _tileTimeout = Duration(seconds: 10);
  static const int _chunkSize = 2000;

  // Roads we consider driveable. OpenMapTiles' `transportation.class` is a
  // controlled vocabulary; we omit service / pedestrian / path / track here.
  static const Set<String> _driveableClasses = <String>{
    'motorway', 'trunk', 'primary', 'secondary', 'tertiary',
    'minor', 'residential', 'living_street', 'unclassified',
    'motorway_link', 'trunk_link', 'primary_link',
    'secondary_link', 'tertiary_link',
  };

  // Quantize lat/lon to ~1 m precision so endpoints from adjacent tiles snap
  // to the same node, stitching the graph across tile boundaries.
  // 1e-5 deg ≈ 1.1 m at the equator.
  static const double _snapStep = 1e-5;

  final http.Client _client;
  final String _styleUrl;
  String? _cachedTileUrlTemplate;

  Future<File> _dbFileFor(int regionId) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory d = Directory(p.join(docs.path, _dir));
    if (!await d.exists()) await d.create(recursive: true);
    return File(p.join(d.path, '$regionId.db'));
  }

  /// Walks the MVT vector tiles for [bbox], extracts driveable road
  /// segments, and writes a directed graph (nodes + edges) into the
  /// per-region SQLite file.
  Future<void> build(
    int regionId,
    LatLngBounds bbox, {
    void Function(double percent)? onProgress,
  }) async {
    onProgress?.call(0);

    final File file = await _dbFileFor(regionId);
    final Database db = await openDatabase(file.path);
    await db.execute('''
      CREATE TABLE IF NOT EXISTS road_nodes(
        id INTEGER PRIMARY KEY,
        lat REAL NOT NULL,
        lon REAL NOT NULL
      )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS road_nodes_lat_idx ON road_nodes(lat)',
    );
    await db.execute('''
      CREATE TABLE IF NOT EXISTS road_edges(
        from_id INTEGER NOT NULL,
        to_id INTEGER NOT NULL,
        length_m REAL NOT NULL
      )''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS road_edges_from_idx ON road_edges(from_id)',
    );
    // Clean any previous graph so reruns don't double-insert.
    await db.delete('road_nodes');
    await db.delete('road_edges');

    final Set<int> seenNodes = <int>{};
    final Set<int> seenEdges = <int>{};
    Batch nodeBatch = db.batch();
    Batch edgeBatch = db.batch();
    int nodePending = 0;
    int edgePending = 0;

    Future<void> flushIfNeeded({bool force = false}) async {
      if (force || nodePending >= _chunkSize) {
        await nodeBatch.commit(noResult: true, continueOnError: true);
        nodeBatch = db.batch();
        nodePending = 0;
      }
      if (force || edgePending >= _chunkSize) {
        await edgeBatch.commit(noResult: true, continueOnError: true);
        edgeBatch = db.batch();
        edgePending = 0;
      }
    }

    int scanned = 0;
    int segments = 0;
    try {
      final String tileUrlTemplate = await _resolveTileUrlTemplate();
      final List<_TileKey> tiles = _enumerateTiles(bbox);
      final int total = tiles.length;
      int done = 0;

      // Parallel chunked fetching — single-tile serial was the bottleneck.
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
          segments += await _extractFromTile(
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
          );
        }
        await flushIfNeeded();
        done += chunk.length;
        if (done % 25 == 0 && total > 0) {
          onProgress?.call(done / total * 95);
        }
      }

      await flushIfNeeded(force: true);
      debugPrint(
        'OfflineRouter MVT: scanned $scanned tiles, '
        '${seenNodes.length} nodes, $segments segments',
      );
    } catch (e, s) {
      debugPrint('OfflineRouter MVT build failed: $e\n$s');
    }

    await db.close();
    onProgress?.call(100);
  }

  // ---------------- MVT helpers ----------------

  Future<String> _resolveTileUrlTemplate() async {
    final String? cached = _cachedTileUrlTemplate;
    if (cached != null) return cached;
    final http.Response res = await _client
        .get(Uri.parse(_styleUrl), headers: <String, String>{
          'User-Agent': _userAgent,
        })
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw OfflineRoutingException(
        'Failed to fetch style.json: HTTP ${res.statusCode}',
      );
    }
    final dynamic decoded = _safeDecode(res.body);
    if (decoded is! Map) {
      throw OfflineRoutingException('Style JSON is not an object');
    }
    final Map<String, dynamic> style = decoded.cast<String, dynamic>();
    final Map<String, dynamic>? sources =
        (style['sources'] as Map?)?.cast<String, dynamic>();
    if (sources == null) {
      throw OfflineRoutingException('Style has no `sources` object');
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
        final dynamic tj = _safeDecode(tjRes.body);
        if (tj is! Map) continue;
        final dynamic tjTiles = (tj.cast<String, dynamic>())['tiles'];
        if (tjTiles is List && tjTiles.isNotEmpty) {
          final String tpl = tjTiles.first as String;
          _cachedTileUrlTemplate = tpl;
          return tpl;
        }
      }
    }
    throw OfflineRoutingException('No vector tile URL found in style');
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

  /// Decodes a single tile's `transportation` features and inserts nodes +
  /// edges into the batches. Returns the number of edges added.
  Future<int> _extractFromTile({
    required Uint8List bytes,
    required int z,
    required int x,
    required int y,
    required Set<int> seenNodes,
    required Set<int> seenEdges,
    required Batch nodeBatch,
    required Batch edgeBatch,
    required void Function(int) addedNodes,
    required void Function(int) addedEdges,
  }) async {
    final VectorTile tile;
    try {
      tile = VectorTile.fromBytes(bytes: bytes);
    } catch (_) {
      return 0;
    }
    int edgesAdded = 0;
    for (final VectorTileLayer layer in tile.layers) {
      if (layer.name != 'transportation') continue;
      final int extent = layer.extent;
      for (final VectorTileFeature feature in layer.features) {
        final Map<String, dynamic> props = _decodeProps(feature);
        final String? cls = props['class'] as String?;
        if (cls == null || !_driveableClasses.contains(cls)) continue;
        final bool oneway = _isOneway(props);

        final List<List<List<double>>> lines = _lineCoords(feature);
        for (final List<List<double>> line in lines) {
          if (line.length < 2) continue;
          int prevId = 0;
          double prevLat = 0;
          double prevLon = 0;
          for (int i = 0; i < line.length; i++) {
            final List<double> pt = line[i];
            if (pt.length < 2) continue;
            final List<double> ll = TileMath.tilePixelToLatLng(
              z, x, y, pt[0], pt[1], extent,
            );
            final int nodeId = _nodeIdFor(ll[0], ll[1]);
            if (seenNodes.add(nodeId)) {
              nodeBatch.insert('road_nodes', <String, dynamic>{
                'id': nodeId,
                'lat': _snap(ll[0]),
                'lon': _snap(ll[1]),
              }, conflictAlgorithm: ConflictAlgorithm.ignore);
              addedNodes(1);
            }
            if (i > 0 && prevId != nodeId) {
              final int edgeKey = _edgeKey(prevId, nodeId);
              if (seenEdges.add(edgeKey)) {
                final double len = _haversine(
                  prevLat, prevLon, ll[0], ll[1],
                );
                edgeBatch.insert('road_edges', <String, dynamic>{
                  'from_id': prevId,
                  'to_id': nodeId,
                  'length_m': len,
                });
                addedEdges(1);
                edgesAdded++;
                if (!oneway) {
                  final int reverseKey = _edgeKey(nodeId, prevId);
                  if (seenEdges.add(reverseKey)) {
                    edgeBatch.insert('road_edges', <String, dynamic>{
                      'from_id': nodeId,
                      'to_id': prevId,
                      'length_m': len,
                    });
                    addedEdges(1);
                    edgesAdded++;
                  }
                }
              }
            }
            prevId = nodeId;
            prevLat = ll[0];
            prevLon = ll[1];
          }
        }
      }
    }
    return edgesAdded;
  }

  /// Collects every line of coordinates (tile-local pixels) from a feature.
  /// Handles LineString and MultiLineString. Returns empty for other types.
  List<List<List<double>>> _lineCoords(VectorTileFeature feature) {
    final Geometry? geom = feature.decodeGeometry<Geometry>();
    if (geom is GeometryLineString) {
      return <List<List<double>>>[geom.coordinates];
    }
    if (geom is GeometryMultiLineString) {
      return geom.coordinates;
    }
    return const <List<List<double>>>[];
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

  bool _isOneway(Map<String, dynamic> props) {
    final dynamic v = props['oneway'];
    if (v is int) return v == 1;
    if (v is String) return v == '1' || v == 'yes' || v == 'true';
    if (v is bool) return v;
    return false;
  }

  /// Quantizes a coordinate to the snap grid.
  double _snap(double v) {
    return (v / _snapStep).round() * _snapStep;
  }

  /// Synthesizes a deterministic 64-bit node ID for a (lat, lon) pair so
  /// the same intersection appearing in adjacent tiles gets the same ID.
  int _nodeIdFor(double lat, double lon) {
    final int latQ = (lat / _snapStep).round();
    final int lonQ = (lon / _snapStep).round();
    // Shift lat into positive range (-90..90 → 0..18_000_000 at 1e-5 deg) and
    // pack into the upper half; lon (-180..180 → 0..36_000_000) into the
    // lower half. Fits in int64 (~6.5e14) with no collisions.
    final int latShifted = latQ + 9000000;
    final int lonShifted = lonQ + 18000000;
    return latShifted * 100000000 + lonShifted;
  }

  /// Composite key for deduplicating edges within a single build. Same
  /// packing trick as nodes; uses node IDs (already bounded above).
  int _edgeKey(int from, int to) {
    // Cantor pairing-ish: stable, order-sensitive, no collisions for sane
    // input ranges. We use simple multiplication since IDs fit in ~50 bits.
    // The seenEdges set is in-memory only, so int64 wraparound risk is fine
    // — collisions would just skip a duplicate insertion attempt.
    return from.hashCode * 31 ^ to.hashCode;
  }

  // ---------------- Routing ----------------

  /// True if the graph DB exists and has at least one row in `road_nodes`.
  /// Lets the dispatcher distinguish "graph wasn't built" from "no path
  /// between these two points".
  Future<bool> hasGraph(int regionId) async {
    final File file = await _dbFileFor(regionId);
    if (!await file.exists()) return false;
    final Database db = await openDatabase(file.path, readOnly: true);
    try {
      final List<Map<String, dynamic>> check = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='road_nodes'",
      );
      if (check.isEmpty) return false;
      final List<Map<String, dynamic>> count =
          await db.rawQuery('SELECT COUNT(1) AS n FROM road_nodes LIMIT 1');
      if (count.isEmpty) return false;
      final dynamic n = count.first['n'];
      return (n is num) && n.toInt() > 0;
    } catch (_) {
      return false;
    } finally {
      await db.close();
    }
  }

  /// Returns the shortest road path from [from] to [to] over the offline
  /// graph for the given region, or null if no route exists or the graph
  /// wasn't built.
  Future<RouteResult?> route(int regionId, LatLng from, LatLng to) async {
    final File file = await _dbFileFor(regionId);
    if (!await file.exists()) return null;
    final Database db = await openDatabase(file.path, readOnly: true);
    try {
      final List<Map<String, dynamic>> check = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='road_nodes'",
      );
      if (check.isEmpty) return null;

      final int? src = await _snapToNearestNode(db, from);
      final int? dst = await _snapToNearestNode(db, to);
      if (src == null || dst == null) return null;
      if (src == dst) {
        final LatLng p = (await _nodeLatLng(db, src))!;
        return RouteResult(
          geometry: <LatLng>[p, p],
          distanceMeters: 0,
          durationSeconds: 0,
        );
      }

      final List<Map<String, dynamic>> edgeRows =
          await db.query('road_edges');
      final Map<int, List<_Edge>> adj = <int, List<_Edge>>{};
      for (final Map<String, dynamic> r in edgeRows) {
        final int fromId = r['from_id'] as int;
        adj
            .putIfAbsent(fromId, () => <_Edge>[])
            .add(_Edge(r['to_id'] as int, (r['length_m'] as num).toDouble()));
      }

      final _DijkstraResult? path = _dijkstra(adj, src, dst);
      if (path == null) return null;

      final List<LatLng> geometry = <LatLng>[];
      for (final int id in path.nodeIds) {
        final LatLng? pt = await _nodeLatLng(db, id);
        if (pt != null) geometry.add(pt);
      }
      if (geometry.length < 2) return null;
      return RouteResult(
        geometry: geometry,
        distanceMeters: path.distance,
        durationSeconds: 0,
      );
    } finally {
      await db.close();
    }
  }

  Future<int?> _snapToNearestNode(Database db, LatLng pt) async {
    for (final double radius in const <double>[0.003, 0.01, 0.05]) {
      final List<Map<String, dynamic>> rows = await db.query(
        'road_nodes',
        where: 'lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?',
        whereArgs: <Object?>[
          pt.latitude - radius,
          pt.latitude + radius,
          pt.longitude - radius,
          pt.longitude + radius,
        ],
      );
      if (rows.isEmpty) continue;
      double best = double.infinity;
      int? bestId;
      for (final Map<String, dynamic> r in rows) {
        final double d = _haversine(
          pt.latitude,
          pt.longitude,
          (r['lat'] as num).toDouble(),
          (r['lon'] as num).toDouble(),
        );
        if (d < best) {
          best = d;
          bestId = r['id'] as int;
        }
      }
      return bestId;
    }
    return null;
  }

  Future<LatLng?> _nodeLatLng(Database db, int id) async {
    final List<Map<String, dynamic>> rows = await db.query(
      'road_nodes',
      columns: <String>['lat', 'lon'],
      where: 'id = ?',
      whereArgs: <Object?>[id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LatLng(
      (rows.first['lat'] as num).toDouble(),
      (rows.first['lon'] as num).toDouble(),
    );
  }

  _DijkstraResult? _dijkstra(Map<int, List<_Edge>> adj, int src, int dst) {
    final Map<int, double> dist = <int, double>{src: 0};
    final Map<int, int> prev = <int, int>{};
    final HeapPriorityQueue<_QItem> pq =
        HeapPriorityQueue<_QItem>(
            (_QItem a, _QItem b) => a.dist.compareTo(b.dist));
    pq.add(_QItem(src, 0));

    while (pq.isNotEmpty) {
      final _QItem cur = pq.removeFirst();
      if (cur.id == dst) {
        final List<int> path = <int>[];
        int? node = dst;
        while (node != null) {
          path.add(node);
          node = prev[node];
        }
        return _DijkstraResult(path.reversed.toList(), cur.dist);
      }
      if (cur.dist > (dist[cur.id] ?? double.infinity)) continue;
      final List<_Edge> neighbors = adj[cur.id] ?? const <_Edge>[];
      for (final _Edge e in neighbors) {
        final double nd = cur.dist + e.length;
        if (nd < (dist[e.to] ?? double.infinity)) {
          dist[e.to] = nd;
          prev[e.to] = cur.id;
          pq.add(_QItem(e.to, nd));
        }
      }
    }
    return null;
  }

  double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const double R = 6371000.0;
    final double dLat = (lat2 - lat1) * math.pi / 180;
    final double dLon = (lon2 - lon1) * math.pi / 180;
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  dynamic _safeDecode(String body) {
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  void dispose() => _client.close();
}

// ===== private types =====

class _TileKey {
  final int z;
  final int x;
  final int y;
  const _TileKey(this.z, this.x, this.y);
}

class _Edge {
  _Edge(this.to, this.length);
  final int to;
  final double length;
}

class _QItem {
  _QItem(this.id, this.dist);
  final int id;
  final double dist;
}

class _DijkstraResult {
  _DijkstraResult(this.nodeIds, this.distance);
  final List<int> nodeIds;
  final double distance;
}
