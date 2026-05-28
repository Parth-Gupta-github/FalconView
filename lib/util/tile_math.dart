import 'dart:math' as math;

class TileXY {
  final int x;
  final int y;
  const TileXY(this.x, this.y);
}

class TileMath {
  const TileMath._();

  /// Convert geographic (lat, lon) to the tile index at the given zoom level.
  /// Standard Web Mercator (EPSG:3857) tile pyramid.
  static TileXY latLngToTile(double lat, double lon, int zoom) {
    final int n = 1 << zoom;
    final int x = ((lon + 180.0) / 360.0 * n).floor().clamp(0, n - 1);
    final double latRad = lat * math.pi / 180.0;
    final int y =
        ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
                2.0 *
                n)
            .floor()
            .clamp(0, n - 1);
    return TileXY(x, y);
  }

  /// Inverse: tile-local pixel coordinates (0..extent) → lat/lon.
  ///
  /// `extent` is the tile's MVT extent (4096 for OpenMapTiles).
  static List<double> tilePixelToLatLng(
    int z,
    int tx,
    int ty,
    num px,
    num py,
    int extent,
  ) {
    final double n = (1 << z).toDouble();
    final double worldX = tx + px / extent;
    final double worldY = ty + py / extent;
    final double lon = worldX / n * 360.0 - 180.0;
    final double latRad =
        math.atan(_sinh(math.pi * (1 - 2 * worldY / n)));
    final double lat = latRad * 180.0 / math.pi;
    return <double>[lat, lon];
  }

  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2.0;

  /// How many (z,x,y) tiles cover the bbox across the inclusive zoom range
  /// `[zMin..zMax]`. Cheap geometric count; does not account for per-tile
  /// data density (water tiles vs city-centre tiles).
  static int tileCountForBbox(
    double south, double west, double north, double east,
    int zMin, int zMax,
  ) {
    int total = 0;
    for (int z = zMin; z <= zMax; z++) {
      final TileXY tl = latLngToTile(north, west, z);
      final TileXY br = latLngToTile(south, east, z);
      final int xMin = tl.x < br.x ? tl.x : br.x;
      final int xMax = tl.x < br.x ? br.x : tl.x;
      final int yMin = tl.y < br.y ? tl.y : br.y;
      final int yMax = tl.y < br.y ? br.y : tl.y;
      total += (xMax - xMin + 1) * (yMax - yMin + 1);
    }
    return total;
  }

  /// Rough on-disk size of an offline region download. Accounts for the
  /// MapLibre tile pyramid plus our POI extract (z12-14) and our router
  /// extract (z13-14). Average tile blob ~25 KB for OpenFreeMap vector
  /// tiles. The number is an estimate — actual size can vary 2-3× with
  /// urban density.
  static String estimatedDownloadSize(
    double south, double west, double north, double east, {
    int mapMinZoom = 10,
    int mapMaxZoom = 16,
    double averageTileKb = 25,
  }) {
    final int mapTiles =
        tileCountForBbox(south, west, north, east, mapMinZoom, mapMaxZoom);
    final int poiTiles =
        tileCountForBbox(south, west, north, east, 12, 14);
    final int routerTiles =
        tileCountForBbox(south, west, north, east, 13, 14);
    final int totalTiles = mapTiles + poiTiles + routerTiles;
    final double bytes = totalTiles * averageTileKb * 1024.0;
    return _formatBytes(bytes);
  }

  static String _formatBytes(double bytes) {
    if (bytes < 1024 * 1024) {
      return '<1 MB';
    }
    final double mb = bytes / (1024 * 1024);
    if (mb < 1000) {
      return '~${mb.round()} MB';
    }
    return '~${(mb / 1024).toStringAsFixed(1)} GB';
  }
}
