package com.muondia.muondia

import android.content.Intent
import android.content.pm.ApplicationInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var visualChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        visualChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "muondia/visual"
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val development = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!development || intent.action != "$packageName.DEV_OPEN_VISUAL") return

        val experience = intent.getStringExtra("experience")
        val state = intent.getStringExtra("state")
        if (experience != "auth" || (state != "inicio" && state != "email")) return

        visualChannel?.invokeMethod(
            "openState",
            mapOf("experience" to experience, "state" to state)
        )
    }
}
