import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "falconview/tilecache",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { (call, result) in
        if call.method == "getOfflineDbPath" {
          result(Self.findOfflineDb())
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  // MapLibre Native on iOS keeps its tile cache under Application Support or
  // Library/Caches. Check the common locations.
  private static func findOfflineDb() -> String? {
    let fm = FileManager.default
    let roots: [URL] = [
      fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
      fm.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Caches"),
      fm.urls(for: .documentDirectory, in: .userDomainMask).first
    ].compactMap { $0 }

    let candidates = ["mbgl-offline.db", "cache.db", "mbtiles_cache.db"]
    for root in roots {
      // Direct hit at root.
      for name in candidates {
        let url = root.appendingPathComponent(name)
        if fm.fileExists(atPath: url.path) { return url.path }
      }
      // Common nested locations.
      for sub in [".mapbox", "maplibre"] {
        let nested = root.appendingPathComponent(sub)
        for name in candidates {
          let url = nested.appendingPathComponent(name)
          if fm.fileExists(atPath: url.path) { return url.path }
        }
      }
    }
    return nil
  }
}
