package com.example.falconview

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "falconview/tilecache"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getOfflineDbPath" -> result.success(findOfflineDb())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * MapLibre Native on Android puts its tile cache in a SQLite file whose
     * exact location and name vary across versions/forks. Walk every plausible
     * directory and pick the first `.db` whose name screams "tile cache".
     */
    private fun findOfflineDb(): String? {
        val ctx = applicationContext
        val roots = mutableListOf<File?>(
            // The legacy default location.
            ctx.getDatabasePath("placeholder").parentFile,
            // Modern MapLibre Native default: <filesDir>/mbgl-offline.db
            ctx.filesDir,
            // Sometimes used by the plugin.
            ctx.cacheDir,
            ctx.noBackupFilesDir,
            ctx.getExternalFilesDir(null),
        ).filterNotNull()

        // Step 1: exact filename hits in any root.
        val filenames = listOf(
            "mbgl-offline.db",
            "mbgl-cache.db",
            "mbtiles_cache.db",
            "cache.db",
            "mapbox-cache.db",
        )
        for (root in roots) {
            for (name in filenames) {
                val f = File(root, name)
                if (f.exists() && f.length() > 0) {
                    android.util.Log.d("FalconView", "Found cache DB: ${f.absolutePath}")
                    return f.absolutePath
                }
            }
        }

        // Step 2: scan each root one level deep for any .db that looks tile-y.
        for (root in roots) {
            val found = scanForCacheDb(root) ?: continue
            android.util.Log.d("FalconView", "Found cache DB (scan): ${found.absolutePath}")
            return found.absolutePath
        }

        android.util.Log.w("FalconView", "No MapLibre offline cache DB found. Roots checked: $roots")
        return null
    }

    private fun scanForCacheDb(dir: File): File? {
        if (!dir.exists() || !dir.isDirectory) return null
        val match = dir.listFiles { f ->
            f.isFile && f.length() > 0 && f.name.endsWith(".db") &&
                (f.name.contains("mbgl", true) ||
                    f.name.contains("maplibre", true) ||
                    f.name.contains("mapbox", true) ||
                    f.name.contains("tile", true) ||
                    f.name.contains("offline", true))
        }
        if (match != null && match.isNotEmpty()) return match[0]

        // One level deeper.
        val subdirs = dir.listFiles { f -> f.isDirectory } ?: return null
        for (sub in subdirs) {
            val r = sub.listFiles { f ->
                f.isFile && f.length() > 0 && f.name.endsWith(".db") &&
                    (f.name.contains("mbgl", true) ||
                        f.name.contains("maplibre", true) ||
                        f.name.contains("mapbox", true) ||
                        f.name.contains("tile", true) ||
                        f.name.contains("offline", true))
            }
            if (r != null && r.isNotEmpty()) return r[0]
        }
        return null
    }
}
