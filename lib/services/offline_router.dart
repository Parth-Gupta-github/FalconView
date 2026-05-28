import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/place.dart';
import 'routing_service.dart' show RouteResult;

class OfflineRoutingException implements Exception {
  OfflineRoutingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OfflineRouter {
  OfflineRouter({http.Client? client}) : _client = client ?? http.Client();

  static const String _overpass = 'https://overpass-api.de/api/interpreter';
  static const String _userAgent = 'FalconView/1.0 (contact: parvtiwari1@gmail.com)';
  static const String _dir = 'region_indexes';

  final http.Client _client;

  Future<File> _dbFileFor(int regionId) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory d = Directory(p.join(docs.path, _dir));
    if (!await d.exists()) await d.create(recursive: true);
    return File(p.join(d.path, '$regionId.db'));
  }

  /// Fetches the road network for [bbox] from Overpass and stores it as a
  /// directed graph in the per-region SQLite database alongside the POI index.
  Future<void> build(
    int regionId,
    LatLngBounds bbox, {
    void Function(double percent)? onProgress,
  }) async {
    onProgress?.call(0);
    final String s = bbox.southwest.latitude.toString();
    final String w = bbox.southwest.longitude.toString();
    final String n = bbox.northeast.latitude.toString();
    final String e = bbox.northeast.longitude.toString();
    final String bb = '$s,$w,$n,$e';

    final String query = '''
[out:json][timeout:120];
way["highway"~"^(motorway|trunk|primary|secondary|tertiary|residential|unclassified|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|living_street)\$"]($bb);
out geom;
''';

    final http.Response res = await _client.post(
      Uri.parse(_overpass),
      headers: <String, String>{
        'User-Agent': _userAgent,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: <String, String>{'data': query},
    );
    if (res.statusCode != 200) {
      throw OfflineRoutingException('Overpass road fetch failed (HTTP ${res.statusCode})');
    }
    onProgress?.call(50);

    final Map<String, dynamic> body = jsonDecode(res.body) as Map<String, dynamic>;
    final List<dynamic> elements = (body['elements'] as List<dynamic>?) ?? const <dynamic>[];

    final File file = await _dbFileFor(regionId);
    final Database db = await openDatabase(file.path);
    await db.execute('''
      CREATE TABLE IF NOT EXISTS road_nodes(
        id INTEGER PRIMARY KEY,
        lat REAL NOT NULL,
        lon REAL NOT NULL
      )''');
    await db.execute('CREATE INDEX IF NOT EXISTS road_nodes_lat_idx ON road_nodes(lat)');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS road_edges(
        from_id INTEGER NOT NULL,
        to_id INTEGER NOT NULL,
        length_m REAL NOT NULL
      )''');
    await db.execute('CREATE INDEX IF NOT EXISTS road_edges_from_idx ON road_edges(from_id)');
    // Clean any previous partial graph for this region.
    await db.delete('road_nodes');
    await db.delete('road_edges');

    // Process and write in chunks so a single Batch never holds more than a few
    // thousand operations — sqflite serialises the whole Batch as one platform
    // channel message, and a 200k-row Batch will OOM the Android decoder.
    const int chunkSize = 2000;
    final Set<int> seenNodes = <int>{};
    Batch nodeBatch = db.batch();
    Batch edgeBatch = db.batch();
    int nodePending = 0;
    int edgePending = 0;
    int processedWays = 0;
    final int totalWays = elements.length;

    Future<void> flushIfNeeded({bool force = false}) async {
      if (force || nodePending >= chunkSize) {
        await nodeBatch.commit(noResult: true, continueOnError: true);
        nodeBatch = db.batch();
        nodePending = 0;
      }
      if (force || edgePending >= chunkSize) {
        await edgeBatch.commit(noResult: true, continueOnError: true);
        edgeBatch = db.batch();
        edgePending = 0;
      }
    }

    for (final dynamic el in elements) {
      if (el is! Map) continue;
      if (el['type'] != 'way') continue;
      final List<dynamic>? nodeIds = (el['nodes'] as List?);
      final List<dynamic>? geom = (el['geometry'] as List?);
      if (nodeIds == null || geom == null) continue;
      if (nodeIds.length != geom.length || nodeIds.length < 2) continue;
      final Map<String, dynamic> tags =
          ((el['tags'] as Map?) ?? const <String, dynamic>{}).cast<String, dynamic>();
      final bool oneway = _isOneway(tags);

      for (int i = 0; i < nodeIds.length; i++) {
        final int nodeId = (nodeIds[i] as num).toInt();
        if (!seenNodes.contains(nodeId)) {
          seenNodes.add(nodeId);
          final Map g = geom[i] as Map;
          nodeBatch.insert(
            'road_nodes',
            <String, dynamic>{
              'id': nodeId,
              'lat': (g['lat'] as num).toDouble(),
              'lon': (g['lon'] as num).toDouble(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
          nodePending++;
        }
        if (i > 0) {
          final int prevId = (nodeIds[i - 1] as num).toInt();
          final Map gPrev = geom[i - 1] as Map;
          final Map gCur = geom[i] as Map;
          final double len = _haversine(
            (gPrev['lat'] as num).toDouble(),
            (gPrev['lon'] as num).toDouble(),
            (gCur['lat'] as num).toDouble(),
            (gCur['lon'] as num).toDouble(),
          );
          edgeBatch.insert('road_edges', <String, dynamic>{
            'from_id': prevId,
            'to_id': nodeId,
            'length_m': len,
          });
          edgePending++;
          if (!oneway) {
            edgeBatch.insert('road_edges', <String, dynamic>{
              'from_id': nodeId,
              'to_id': prevId,
              'length_m': len,
            });
            edgePending++;
          }
        }
      }
      await flushIfNeeded();
      processedWays++;
      if (processedWays % 200 == 0 && totalWays > 0) {
        // Map the parse/insert work into 50..100% of the overall router-build
        // progress so the UI doesn't appear frozen between Overpass response
        // and DB completion.
        onProgress?.call(50 + (processedWays / totalWays) * 50);
      }
    }

    await flushIfNeeded(force: true);
    await db.close();
    onProgress?.call(100);
  }

  /// Returns the shortest road path from [from] to [to] over the offline graph
  /// for the given region, or null if no route exists or the graph wasn't built.
  Future<RouteResult?> route(int regionId, LatLng from, LatLng to) async {
    final File file = await _dbFileFor(regionId);
    if (!await file.exists()) return null;
    final Database db = await openDatabase(file.path, readOnly: true);
    try {
      final List<Map<String, dynamic>> check =
          await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name='road_nodes'");
      if (check.isEmpty) return null;

      final int? src = await _snapToNearestNode(db, from);
      final int? dst = await _snapToNearestNode(db, to);
      if (src == null || dst == null) return null;
      if (src == dst) {
        final LatLng p = (await _nodeLatLng(db, src))!;
        return RouteResult(geometry: <LatLng>[p, p], distanceMeters: 0, durationSeconds: 0);
      }

      // Load entire edge graph into memory. Cheap for city-sized regions
      // (~200k entries × ~40 bytes = ~8 MB).
      final List<Map<String, dynamic>> edgeRows = await db.query('road_edges');
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
        final LatLng? p = await _nodeLatLng(db, id);
        if (p != null) geometry.add(p);
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

  Future<int?> _snapToNearestNode(Database db, LatLng p) async {
    // Search progressively-larger boxes until we find any node.
    for (final double radius in const <double>[0.003, 0.01, 0.05]) {
      final List<Map<String, dynamic>> rows = await db.query(
        'road_nodes',
        where: 'lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?',
        whereArgs: <Object?>[
          p.latitude - radius,
          p.latitude + radius,
          p.longitude - radius,
          p.longitude + radius,
        ],
      );
      if (rows.isEmpty) continue;
      double best = double.infinity;
      int? bestId;
      for (final Map<String, dynamic> r in rows) {
        final double d = _haversine(
          p.latitude,
          p.longitude,
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
        HeapPriorityQueue<_QItem>((_QItem a, _QItem b) => a.dist.compareTo(b.dist));
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

  bool _isOneway(Map<String, dynamic> tags) {
    final dynamic v = tags['oneway'];
    if (v is! String) return false;
    return v == 'yes' || v == 'true' || v == '1';
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

  void dispose() => _client.close();
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
