import 'dart:convert';

/// Rewrites the full online style so its vector tiles come from the local
/// [LocalTileServer] instead of the network, while keeping ALL of its layers,
/// glyphs and sprite. The offline map then looks identical to the online one —
/// same colours, place names and POI labels/icons — instead of the stripped
/// geometry-only fallback below.
///
/// Glyphs/sprite still point at their original (OpenFreeMap) URLs; the webview
/// HTTP cache serves them offline after they've been fetched once online, so
/// labels keep working without bundling fonts.
String buildOfflineStyleFromOnline(
  String onlineStyleJson,
  String tileUrlTemplate,
) {
  final Map<String, dynamic> style =
      jsonDecode(onlineStyleJson) as Map<String, dynamic>;
  final Map<String, dynamic>? sources =
      (style['sources'] as Map?)?.cast<String, dynamic>();
  if (sources != null) {
    for (final MapEntry<String, dynamic> e in sources.entries) {
      final Map<String, dynamic>? src = (e.value as Map?)?.cast<String, dynamic>();
      if (src == null) continue;
      if (src['type'] == 'vector') {
        // Point this source at the local tile server; drop the TileJSON url so
        // MapLibre doesn't try to fetch it over the network.
        src['tiles'] = <String>[tileUrlTemplate];
        src['minzoom'] = 0;
        src['maxzoom'] = 14;
        src.remove('url');
      }
    }
  }
  return jsonEncode(style);
}

/// Builds a self-contained MapLibre style that renders the OpenMapTiles schema
/// from a local vector-tile URL (the [LocalTileServer]). It uses **no glyphs
/// or sprite**, so it has zero network dependency — the trade-off is that text
/// labels and POI icons aren't drawn (geometry only). Fonts/sprite can be
/// bundled and added later to enable labels offline.
String buildOfflineStyle(String tileUrlTemplate) {
  final Map<String, dynamic> style = <String, dynamic>{
    'version': 8,
    'name': 'FalconView Offline',
    'sources': <String, dynamic>{
      'omt': <String, dynamic>{
        'type': 'vector',
        'tiles': <String>[tileUrlTemplate],
        'minzoom': 0,
        'maxzoom': 14,
        // OSM/ODbL attribution surfaced through MapLibre's attribution control.
        'attribution':
            '© OpenStreetMap contributors · OpenMapTiles · Planetiler',
      },
    },
    'layers': <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'background',
        'type': 'background',
        'paint': <String, dynamic>{'background-color': '#eceff1'},
      },
      <String, dynamic>{
        'id': 'landcover',
        'type': 'fill',
        'source': 'omt',
        'source-layer': 'landcover',
        'paint': <String, dynamic>{
          'fill-color': '#d7e7c8',
          'fill-opacity': 0.6,
        },
      },
      <String, dynamic>{
        'id': 'landuse',
        'type': 'fill',
        'source': 'omt',
        'source-layer': 'landuse',
        'paint': <String, dynamic>{
          'fill-color': '#e8eadf',
          'fill-opacity': 0.6,
        },
      },
      <String, dynamic>{
        'id': 'park',
        'type': 'fill',
        'source': 'omt',
        'source-layer': 'park',
        'paint': <String, dynamic>{
          'fill-color': '#c8e6c9',
          'fill-opacity': 0.6,
        },
      },
      <String, dynamic>{
        'id': 'water',
        'type': 'fill',
        'source': 'omt',
        'source-layer': 'water',
        'paint': <String, dynamic>{'fill-color': '#9cc1e8'},
      },
      <String, dynamic>{
        'id': 'waterway',
        'type': 'line',
        'source': 'omt',
        'source-layer': 'waterway',
        'paint': <String, dynamic>{
          'line-color': '#9cc1e8',
          'line-width': 1.2,
        },
      },
      <String, dynamic>{
        'id': 'building',
        'type': 'fill',
        'source': 'omt',
        'source-layer': 'building',
        'minzoom': 13,
        'paint': <String, dynamic>{
          'fill-color': '#d9d0c3',
          'fill-opacity': 0.7,
        },
      },
      // Minor roads under major roads.
      <String, dynamic>{
        'id': 'roads-minor',
        'type': 'line',
        'source': 'omt',
        'source-layer': 'transportation',
        'filter': <dynamic>[
          'in',
          'class',
          'minor',
          'service',
          'residential',
          'living_street',
          'unclassified',
        ],
        'paint': <String, dynamic>{
          'line-color': '#ffffff',
          'line-width': <dynamic>[
            'interpolate',
            <dynamic>['linear'],
            <dynamic>['zoom'],
            12,
            0.5,
            16,
            3.0,
          ],
        },
      },
      <String, dynamic>{
        'id': 'roads-major',
        'type': 'line',
        'source': 'omt',
        'source-layer': 'transportation',
        'filter': <dynamic>[
          'in',
          'class',
          'motorway',
          'trunk',
          'primary',
          'secondary',
          'tertiary',
        ],
        'paint': <String, dynamic>{
          'line-color': '#f6c177',
          'line-width': <dynamic>[
            'interpolate',
            <dynamic>['linear'],
            <dynamic>['zoom'],
            8,
            0.8,
            16,
            6.0,
          ],
        },
      },
      <String, dynamic>{
        'id': 'boundary',
        'type': 'line',
        'source': 'omt',
        'source-layer': 'boundary',
        'paint': <String, dynamic>{
          'line-color': '#9e9e9e',
          'line-dasharray': <double>[2, 2],
          'line-width': 1.0,
        },
      },
    ],
  };
  return jsonEncode(style);
}