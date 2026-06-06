import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../services/web_map_controller.dart';

/// True on the desktop platforms where the native MapLibre SDK has no Flutter
/// binding and we fall back to MapLibre GL JS in a webview. Uses
/// [defaultTargetPlatform] (not `dart:io`) so it is safe to evaluate on web.
bool get isDesktopMapPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Hosts a MapLibre GL JS map inside an [InAppWebView] and exposes a
/// [WebMapController] for the parent to drive it. The map renders vector tiles
/// on the GPU (WebGL), so it matches the native SDK's smoothness without the
/// raster/PNG latency of a Flutter-canvas renderer.
///
/// The parent supplies the MapLibre [styleJson] (the same document the native
/// `MapLibreMap.styleString` uses — online or the offline localhost-tile
/// style) and receives the controller via [onControllerReady] once the map has
/// finished loading.
class WebMapView extends StatefulWidget {
  const WebMapView({
    super.key,
    required this.styleJson,
    required this.onControllerReady,
    this.onCameraChanged,
    this.onMapClick,
  });

  /// Initial MapLibre style document. Pushed to the map as soon as it is ready.
  final String styleJson;

  /// Called once after the map's first style load, with a ready controller.
  final void Function(WebMapController controller) onControllerReady;

  /// Forwarded camera updates: (lat, lng, zoom, bearing).
  final void Function(double lat, double lng, double zoom, double bearing)?
      onCameraChanged;

  /// Forwarded map taps: (lat, lng, xPixel, yPixel).
  final void Function(double lat, double lng, double x, double y)? onMapClick;

  @override
  State<WebMapView> createState() => _WebMapViewState();
}

class _WebMapViewState extends State<WebMapView> {
  InAppWebViewController? _web;
  WebMapController? _controller;

  @override
  void didUpdateWidget(WebMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep event callbacks current if the parent passed new closures.
    _controller
      ?..onCameraChanged = widget.onCameraChanged
      ..onMapClick = widget.onMapClick;
    // Push a new style if the parent swapped it (e.g. offline MBTiles imported).
    if (oldWidget.styleJson != widget.styleJson && (_controller?.isReady ?? false)) {
      _controller!.setStyle(widget.styleJson, diff: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialFile: 'assets/web_map/index.html',
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        // The offline style fetches tiles from http://127.0.0.1:<port>; allow
        // the file-origin page to reach it.
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
        // Desktop: let MapLibre own scroll/zoom gestures.
        supportZoom: false,
      ),
      onWebViewCreated: (InAppWebViewController c) {
        _web = c;
        final WebMapController controller = WebMapController(
          (String js) async {
            await _web?.evaluateJavascript(source: js);
          },
        );
        controller.onCameraChanged = widget.onCameraChanged;
        controller.onMapClick = widget.onMapClick;
        controller.onReady = () {
          // Push the real style the moment the map canvas is live, then hand
          // the controller to the parent so it can start driving overlays.
          controller.setStyle(widget.styleJson, diff: false);
          widget.onControllerReady(controller);
        };
        _controller = controller;

        // JS -> Dart event channel. The host page calls
        // flutter_inappwebview.callHandler('fvEvent', payload).
        c.addJavaScriptHandler(
          handlerName: 'fvEvent',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            final Object? first = args.first;
            if (first is Map) {
              final Map<String, dynamic> e = first.map(
                (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
              );
              if (e['type'] == 'error') {
                debugPrint('WebMapView JS error: ${e['message']} (${e['cmd']})');
                return;
              }
              _controller?.handleEvent(e);
            }
          },
        );
      },
      onConsoleMessage: (_, ConsoleMessage msg) {
        if (msg.messageLevel == ConsoleMessageLevel.ERROR) {
          debugPrint('WebMapView console: ${msg.message}');
        }
      },
    );
  }
}
