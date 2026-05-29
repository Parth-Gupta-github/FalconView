import 'package:flutter/services.dart' show rootBundle;

import '../models/app_tier.dart';

/// Per-tier map configuration.
///
/// `styleUrl` drives the maplibre native offline downloader (it needs an
/// HTTP URL so it can fetch and cache the style + tiles + glyphs + sprite).
///
/// `renderStyleAsset` is the bundled custom style JSON used for *rendering* —
/// retuned to a Google-Maps-like palette while still reading the same
/// OpenFreeMap tile source. MapScreen loads its contents via [loadRenderStyle]
/// and hands the string to MapLibreMap.styleString.
class TileConfig {
  final String styleUrl;
  final String renderStyleAsset;
  final double offlineMinZoom;
  final double offlineMaxZoom;
  final double interactiveMaxZoom;

  const TileConfig({
    required this.styleUrl,
    required this.renderStyleAsset,
    required this.offlineMinZoom,
    required this.offlineMaxZoom,
    required this.interactiveMaxZoom,
  });

  static const String _bundledStreets =
      'assets/styles/falconview_streets.json';

  static const TileConfig _free = TileConfig(
    styleUrl: 'https://tiles.openfreemap.org/styles/liberty',
    renderStyleAsset: _bundledStreets,
    offlineMinZoom: 10,
    offlineMaxZoom: 14,
    interactiveMaxZoom: 16,
  );

  static const TileConfig _pro = TileConfig(
    styleUrl: 'https://tiles.openfreemap.org/styles/liberty',
    renderStyleAsset: _bundledStreets,
    offlineMinZoom: 10,
    offlineMaxZoom: 16,
    interactiveMaxZoom: 22,
  );

  static TileConfig forTier(AppTier tier) {
    switch (tier) {
      case AppTier.free:
        return _free;
      case AppTier.pro:
        return _pro;
    }
  }

  /// Reads the bundled style JSON and returns it as a string suitable for
  /// `MapLibreMap.styleString`. Cached after first load — the asset is
  /// ~6 KB but rebuilds happen often.
  static String? _cached;
  Future<String> loadRenderStyle() async {
    final String? hit = _cached;
    if (hit != null) return hit;
    final String s = await rootBundle.loadString(renderStyleAsset);
    _cached = s;
    return s;
  }
}
