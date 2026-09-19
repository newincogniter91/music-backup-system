package com.newincogniter91.musicbackup

import android.media.MediaScannerConnection
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.newincogniter91.musicbackup/media"
        ).setMethodCallHandler { call, result ->
            if (call.method == "scanFile") {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("ARG", "path mancante", null)
                } else {
                    // Solo indicizzazione: il file non viene toccato.
                    MediaScannerConnection.scanFile(applicationContext, arrayOf(path), null, null)
                    result.success(null)
                }
            } else if (call.method == "getStorageRoots") {
                // Radici delle memorie (interna + SD), ricavate dalle cartelle
                // dell'app su ogni volume: /storage/XXXX-XXXX/Android/data/... -> /storage/XXXX-XXXX
                val roots = mutableListOf<String>()
                for (dir in applicationContext.getExternalFilesDirs(null)) {
                    val path = dir?.absolutePath ?: continue
                    val idx = path.indexOf("/Android/data")
                    if (idx > 0) roots.add(path.substring(0, idx))
                }
                result.success(roots)
            } else {
                result.notImplemented()
            }
        }
    }
}
