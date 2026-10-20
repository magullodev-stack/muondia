package com.muondia.muondia

import android.content.Intent
import android.content.pm.ApplicationInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var visualChannel: MethodChannel? = null
    private val debugMode: Boolean
        get() = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "muondia/visual"
        )
        visualChannel = channel
        channel.setMethodCallHandler { call, result ->
            if (!debugMode || call.method != "setActiveLocation") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val mode = call.argument<String>("mode")
            val experience = call.argument<String>("experience")
            val state = call.argument<String>("state")
            val hidden = call.argument<List<String>>("hidden") ?: emptyList()
            if (mode !in setOf("preview", "real") ||
                experience != "auth" || state !in setOf("inicio", "email") ||
                hidden.any { it !in setOf("background", "robot", "logo", "googleIcon") }) {
                result.error("invalid_location", "Pantalla no registrada.", null)
                return@setMethodCallHandler
            }
            try {
                File(filesDir, "muondia_active_visual.txt")
                    .writeText("$mode:$experience:$state:${hidden.distinct().sorted().joinToString(",")}")
                result.success(null)
            } catch (_: Exception) {
                result.error("write_failed", "No se pudo guardar la pantalla activa.", null)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (!debugMode) return
        when (intent.action) {
            "$packageName.DEV_OPEN_VISUAL" -> {
                val experience = intent.getStringExtra("experience")
                val state = intent.getStringExtra("state")
                if (experience != "auth" || state !in setOf("inicio", "email")) return
                visualChannel?.invokeMethod("openState",
                    mapOf("experience" to experience, "state" to state))
            }
            "$packageName.DEV_OPEN_REAL_FLOW" -> {
                visualChannel?.invokeMethod("openRealFlow", null)
            }
            "$packageName.DEV_ASSET_VISIBILITY" -> {
                val name = intent.getStringExtra("name")
                if (name !in setOf("background", "robot", "logo", "googleIcon")) return
                visualChannel?.invokeMethod("setVisibility",
                    mapOf("name" to name, "visible" to
                        intent.getBooleanExtra("visible", true)))
            }
        }
    }
}
