import '../models/app_tier.dart';

/// Per-tier map configuration.
///
/// Free tier uses OpenFreeMap (zoom 14 source data); Pro raises the
/// interactive ceiling so users can pinch into overzoom or, when a paid
/// tile provider key is wired in, into genuine high-zoom data.
class TileConfig {
  final String styleUrl;
  final double offlineMinZoom;
  final double offlineMaxZoom;
  final double interactiveMaxZoom;

  const TileConfig({
    required this.styleUrl,
    required this.offlineMinZoom,
    required this.offlineMaxZoom,
    required this.interactiveMaxZoom,
  });

  static const TileConfig _free = TileConfig(
    styleUrl: 'https://tiles.openfreemap.org/styles/liberty',
    offlineMinZoom: 10,
    offlineMaxZoom: 14,
    interactiveMaxZoom: 16,
  );

  // Pro: same source for now (no paid provider key wired in yet). When you
  // swap in MapTiler/Mapbox, just change `styleUrl` here — every consumer
  // reads through this single point.
  static const TileConfig _pro = TileConfig(
    styleUrl: 'https://tiles.openfreemap.org/styles/liberty',
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
}
