// Esri World Imagery — free (no API key), high-resolution aerial/satellite
// tiles down to ~sub-meter, available to ~zoom 19, refreshed by Esri on a
// rolling basis. The sharpest of the no-key sources, so it stays useful all
// the way to street level.
//
// This is an online source (tiles stream over the network; not bundled for
// offline use). It is added at runtime as a single raster *layer* on top of
// the vector basemap — below the app's overlay layers — so pins, ruler lines,
// routes and the GPS marker survive toggling satellite on/off (the MapLibre
// style itself is never reloaded).
//
// Licensing: free to use with visible attribution (included below). Esri's
// terms restrict heavy/commercial use of the public service — review them if
// this ships at scale.

/// Esri World Imagery serves tiles to ~zoom 19; MapLibre over-zooms beyond.
const double kEsriMaxZoom = 19;

/// ArcGIS REST tile endpoint. Path order is `{z}/{y}/{x}` (level/row/col).
const String kEsriWorldImageryTileUrl =
    'https://server.arcgisonline.com/ArcGIS/rest/services/'
    'World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// Esri's terms require visible attribution for World Imagery.
const String kEsriWorldImageryAttribution =
    'Imagery © Esri';