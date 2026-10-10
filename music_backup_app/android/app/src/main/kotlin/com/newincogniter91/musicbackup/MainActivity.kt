package com.newincogniter91.musicbackup

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "musicbackup/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // start e update fanno la stessa cosa: avviano il service
                    // o ne aggiornano la notifica.
                    "start", "update" -> {
                        val intent = Intent(this, UploadService::class.java)
                            .putExtra(UploadService.EXTRA_TEXT, call.argument<String>("text"))
                            .putExtra(UploadService.EXTRA_PERCENT, call.argument<Int>("percent") ?: -1)
                        try {
                            ContextCompat.startForegroundService(this, intent)
                            result.success(null)
                        } catch (e: Throwable) {
                            result.error("service", e.message, null)
                        }
                    }
                    "stop" -> {
                        startService(
                            Intent(this, UploadService::class.java).setAction(UploadService.ACTION_STOP)
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
