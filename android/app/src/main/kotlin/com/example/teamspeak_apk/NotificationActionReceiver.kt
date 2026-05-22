package com.senlinjun.nek0

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class NotificationActionReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_TOGGLE_MUTE = "com.senlinjun.nek0.TOGGLE_MUTE"
        const val ACTION_DISCONNECT = "com.senlinjun.nek0.DISCONNECT"
        private const val CHANNEL = "com.senlinjun.nek0/service"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val engine = FlutterEngineCache.getInstance().get("teamspeak_engine") ?: return
        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        when (intent.action) {
            ACTION_TOGGLE_MUTE -> {
                val inputMuted = intent.getBooleanExtra("input_muted", false)
                channel.invokeMethod("toggle_mute", mapOf("input_muted" to inputMuted))
            }
            ACTION_DISCONNECT -> {
                channel.invokeMethod("disconnect", null)
            }
        }
    }
}
