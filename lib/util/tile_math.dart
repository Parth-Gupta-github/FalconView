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
}
