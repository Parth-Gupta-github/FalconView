import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
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

/// Offline road-graph storage + query layer.
///
/// Tile fetching is owned by [OfflineSearchIndex] — it walks each tile once
/// and calls [extractFromTile] here to decode the `transportation` layer
/// alongside the POI extraction in the same pass. We just provide:
///   * table setup helpers
///   * per-tile MVT → (nodes, edges) decoding
///   * Dijkstra route(...) over the on-disk graph
class OfflineRouter {
  OfflineRouter();

  static const String _dir = 'region_indexes';

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
  static const double _snapStep = 1e-5;

  Future<File> _dbFileFor(int regionId) async {
    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory d = Directory(p.join(docs.path, _dir));
    if (!await d.exists()) await d.create(recursive: true);
    return File(p.join(d.path, '$regionId.db'));
  }

  /// Creates the road-graph tables in [db]. Idempotent — uses IF NOT EXISTS.
  /// Called by [OfflineSearchIndex.build] when it sets up the per-region DB.
  Future<void> setupTables(Database db) async {
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
  }

  /// Decodes the `transportation` layer of a single MVT tile and queues
  /// node + edge inserts into [nodeBatch] and [edgeBatch]. The caller manages
  /// flushing. [seenNodes] and [seenEdges] dedupe across tiles.
  ///
  /// Returns the number of edges added by this tile (purely for metrics).
  int extractFromTile({
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
    bool Function(double lat, double lon)? contains,
  }) {
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
          bool prevInside = false;
          for (int i = 0; i < line.length; i++) {
            final List<double> pt = line[i];
            if (pt.length < 2) continue;
            final List<double> ll = TileMath.tilePixelToLatLng(
              z, x, y, pt[0], pt[1], extent,
            );
            // Clip the road graph to the user-drawn area: keep a node only if
            // it falls inside, and an edge only when both endpoints do. Roads
            // crossing the boundary are truncated at it.
            final bool inside = contains == null || contains(ll[0], ll[1]);
            final int nodeId = _nodeIdFor(ll[0], ll[1]);
            if (inside && seenNodes.add(nodeId)) {
              nodeBatch.insert('road_nodes', <String, dynamic>{
                'id': nodeId,
                'lat': _snap(ll[0]),
                'lon': _snap(ll[1]),
              }, conflictAlgorithm: ConflictAlgorithm.ignore);
              addedNodes(1);
            }
            if (i > 0 && prevId != nodeId && inside && prevInside) {
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
            prevInside = inside;
          }
        }
      }
    }
    return edgesAdded;
  }

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

  double _snap(double v) => (v / _snapStep).round() * _snapStep;

  int _nodeIdFor(double lat, double lon) {
    final int latQ = (lat / _snapStep).round();
    final int lonQ = (lon / _snapStep).round();
    final int latShifted = latQ + 9000000;
    final int lonShifted = lonQ + 18000000;
    return latShifted * 100000000 + lonShifted;
  }

  int _edgeKey(int from, int to) {
    return from.hashCode * 31 ^ to.hashCode;
  }

  // ---------------- Query side ----------------

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
        final LatLng pt = (await _nodeLatLng(db, src))!;
        return RouteResult(
          geometry: <LatLng>[pt, pt],
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
    final HeapPriorityQueue<_QItem> pq = HeapPriorityQueue<_QItem>(
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

  void dispose() {}
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
