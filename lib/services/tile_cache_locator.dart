import 'package:flutter/services.dart';

/// Bridge to the native side that finds MapLibre Native's offline tile cache
/// SQLite file. Returns `null` if the file can't be located.
class TileCacheLocator {
  static const MethodChannel _channel = MethodChannel('falconview/tilecache');

  static Future<String?> path() async {
    try {
      return await _channel.invokeMethod<String>('getOfflineDbPath');
    } catch (_) {
      return null;
    }
  }
}
