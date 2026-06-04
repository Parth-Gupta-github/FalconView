import 'dart:convert';

/// Builds a self-contained MapLibre style that renders the OpenMapTiles schema
/// from local URLs only — vector tiles, glyph PBFs, and the sprite all live on
/// the loopback [LocalTileServer], so the basemap (including text labels and
/// POI icons) renders fully offline.
///
/// Labels are pulled from the `place`, `transportation_name`, and `poi`
/// source-layers; their text fields use `{name:latin}` so they read whether
/// or not Devanagari glyphs are available for a given POI.
String buildOfflineStyle(
  String tileUrlTemplate, {
  required String glyphsUrlTemplate,
  required String spriteUrlBase,
}) {
  final Map<String, dynamic> style = <String, dynamic>{
    'version': 8,
    'name': 'FalconView Offline',
    'glyphs': glyphsUrlTemplate,
    'sprite': spriteUrlBase,
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

      // ---------------- Labels ----------------
      // Mirrors the symbol layers in `assets/styles/falconview_streets.json`
      // but reads from the offline `omt` source. {name:latin} so labels render
      // even when the local glyph bundle only covers the 0-255 + Devanagari
      // ranges.

      <String, dynamic>{
        'id': 'road-label',
        'type': 'symbol',
        'source': 'omt',
        'source-layer': 'transportation_name',
        'minzoom': 13,
        'filter': <dynamic>[
          'in',
          'class',
          'motorway',
          'trunk',
          'primary',
          'secondary',
          'tertiary',
          'minor',
        ],
        'layout': <String, dynamic>{
          'text-field': '{name:latin}',
          'text-font': <String>['Noto Sans Regular'],
          'text-size': <String, dynamic>{
            'stops': <List<double>>[
              <double>[13, 10],
              <double>[18, 14],
            ],
          },
          'symbol-placement': 'line',
          'text-rotation-alignment': 'map',
        },
        'paint': <String, dynamic>{
          'text-color': '#5F5F5F',
          'text-halo-color': '#FFFFFF',
          'text-halo-width': 2,
        },
      },
      <String, dynamic>{
        'id': 'place-village',
        'type': 'symbol',
        'source': 'omt',
        'source-layer': 'place',
        'minzoom': 10,
        'filter': <dynamic>[
          'in',
          'class',
          'village',
          'suburb',
          'neighbourhood',
        ],
        'layout': <String, dynamic>{
          'text-field': '{name:latin}',
          'text-font': <String>['Noto Sans Regular'],
          'text-size': <String, dynamic>{
            'stops': <List<double>>[
              <double>[10, 10],
              <double>[16, 14],
            ],
          },
        },
        'paint': <String, dynamic>{
          'text-color': '#5F5F5F',
          'text-halo-color': '#F0F0F0',
          'text-halo-width': 1.4,
        },
      },
      <String, dynamic>{
        'id': 'place-town',
        'type': 'symbol',
        'source': 'omt',
        'source-layer': 'place',
        'minzoom': 8,
        'filter': <dynamic>['==', 'class', 'town'],
        'layout': <String, dynamic>{
          'text-field': '{name:latin}',
          'text-font': <String>['Noto Sans Bold'],
          'text-size': <String, dynamic>{
            'stops': <List<double>>[
              <double>[8, 11],
              <double>[14, 16],
            ],
          },
        },
        'paint': <String, dynamic>{
          'text-color': '#3D3D3D',
          'text-halo-color': '#F0F0F0',
          'text-halo-width': 1.6,
        },
      },
      <String, dynamic>{
        'id': 'place-city',
        'type': 'symbol',
        'source': 'omt',
        'source-layer': 'place',
        'minzoom': 5,
        'filter': <dynamic>['==', 'class', 'city'],
        'layout': <String, dynamic>{
          'text-field': '{name:latin}',
          'text-font': <String>['Noto Sans Bold'],
          'text-size': <String, dynamic>{
            'stops': <List<double>>[
              <double>[5, 12],
              <double>[12, 20],
            ],
          },
        },
        'paint': <String, dynamic>{
          'text-color': '#262626',
          'text-halo-color': '#F0F0F0',
          'text-halo-width': 1.8,
        },
      },
      <String, dynamic>{
        'id': 'place-country',
        'type': 'symbol',
        'source': 'omt',
        'source-layer': 'place',
        'maxzoom': 8,
        'filter': <dynamic>['==', 'class', 'country'],
        'layout': <String, dynamic>{
          'text-field': '{name:latin}',
          'text-font': <String>['Noto Sans Bold'],
          'text-size': <String, dynamic>{
            'stops': <List<double>>[
              <double>[2, 11],
              <double>[6, 18],
            ],
          },
          'text-transform': 'uppercase',
          'text-letter-spacing': 0.15,
        },
        'paint': <String, dynamic>{
          'text-color': '#262626',
          'text-halo-color': '#F0F0F0',
          'text-halo-width': 2,
        },
      },
      <String, dynamic>{
        'id': 'poi-major',
        'type': 'symbol',
        'source': 'omt',
        'source-layer': 'poi',
        'minzoom': 14,
        'filter': <dynamic>[
          'any',
          <dynamic>['==', 'class', 'hospital'],
          <dynamic>['==', 'class', 'school'],
          <dynamic>['==', 'class', 'college'],
          <dynamic>['==', 'class', 'place_of_worship'],
          <dynamic>['==', 'class', 'stadium'],
          <dynamic>['==', 'class', 'shopping'],
          <dynamic>['==', 'class', 'lodging'],
        ],
        'layout': <String, dynamic>{
          'text-field': '{name:latin}',
          'text-font': <String>['Noto Sans Regular'],
          'text-size': <String, dynamic>{
            'stops': <List<double>>[
              <double>[14, 10],
              <double>[18, 13],
            ],
          },
          'text-anchor': 'top',
          'text-offset': <double>[0, 0.6],
        },
        'paint': <String, dynamic>{
          'text-color': '#6A6A6A',
          'text-halo-color': '#F0F0F0',
          'text-halo-width': 1.4,
        },
      },
      // A wider POI label layer for the long tail (shops, food, transit
      // stops, etc.). Kicks in one zoom deeper so the city overview isn't
      // littered with shop names.
      <String, dynamic>{
        'id': 'poi-minor',
        'type': 'symbol',
        'source': 'omt',
        'source-layer': 'poi',
        'minzoom': 15,
        'filter': <dynamic>[
          '!in',
          'class',
          'hospital',
          'school',
          'college',
          'place_of_worship',
          'stadium',
          'shopping',
          'lodging',
        ],
        'layout': <String, dynamic>{
          'text-field': '{name:latin}',
          'text-font': <String>['Noto Sans Regular'],
          'text-size': <String, dynamic>{
            'stops': <List<double>>[
              <double>[15, 9],
              <double>[18, 12],
            ],
          },
          'text-anchor': 'top',
          'text-offset': <double>[0, 0.5],
          'text-optional': true,
        },
        'paint': <String, dynamic>{
          'text-color': '#7A7A7A',
          'text-halo-color': '#F0F0F0',
          'text-halo-width': 1.2,
        },
      },
    ],
  };
  return jsonEncode(style);
}
