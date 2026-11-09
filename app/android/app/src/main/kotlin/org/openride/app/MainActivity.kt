package org.openride.app

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "openride/foreground_service"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(this, RecordingService::class.java).apply {
                        putExtra(RecordingService.EXTRA_TITLE, call.argument<String>("title"))
                        putExtra(RecordingService.EXTRA_TEXT, call.argument<String>("text"))
                    }
                    ContextCompat.startForegroundService(this, intent)
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, RecordingService::class.java))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
