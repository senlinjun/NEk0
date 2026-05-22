package com.senlinjun.nek0

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class KeepAliveService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val CHANNEL_ID = "teamspeak_keepalive"
        const val NOTIFICATION_ID = 1

        init {
            try { System.loadLibrary("tsclient") } catch (_: Exception) {}
        }

        @JvmStatic external fun tsDisconnect()

        // Stored for NotificationActionReceiver to rebuild notification after actions
        @JvmField var lastTitle: String = "TeamSpeak"
        @JvmField var lastText: String = "Connected"
        @JvmField var lastInputMuted: Boolean = false

        fun start(context: Context, title: String, text: String, mic: Boolean = false, inputMuted: Boolean = false) {
            lastTitle = title
            lastText = text
            lastInputMuted = inputMuted
            val intent = Intent(context, KeepAliveService::class.java).apply {
                putExtra("title", title)
                putExtra("text", text)
                putExtra("mic", mic)
                putExtra("input_muted", inputMuted)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        fun update(context: Context, title: String, text: String, mic: Boolean = false, inputMuted: Boolean = false) {
            lastTitle = title
            lastText = text
            lastInputMuted = inputMuted
            val notification = buildNotification(context, title, text, inputMuted)
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, notification)
            // Restart service to update foreground service type (Android 14+)
            val serviceIntent = Intent(context, KeepAliveService::class.java).apply {
                putExtra("title", title)
                putExtra("text", text)
                putExtra("mic", mic)
                putExtra("input_muted", inputMuted)
            }
            context.startService(serviceIntent)
        }

        @JvmStatic
        fun buildNotification(context: Context, title: String, text: String, inputMuted: Boolean = false): Notification {
            val launchIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getActivity(context, 0, launchIntent, flags)

            // Mute toggle action
            val muteIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                action = NotificationActionReceiver.ACTION_TOGGLE_MUTE
                putExtra("input_muted", !inputMuted)
            }
            val mutePending = PendingIntent.getBroadcast(context, 1, muteIntent, flags)

            // Disconnect action
            val discIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                action = NotificationActionReceiver.ACTION_DISCONNECT
            }
            val discPending = PendingIntent.getBroadcast(context, 2, discIntent, flags)

            val muteIcon = if (inputMuted) R.drawable.ic_mic_off else R.drawable.ic_mic
            val muteLabel = if (inputMuted) "Unmute" else "Mute"

            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setOngoing(true)
                    .setContentIntent(pendingIntent)
                    .addAction(muteIcon, muteLabel, mutePending)
                    .addAction(R.drawable.ic_disconnect, "Disconnect", discPending)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setOngoing(true)
                    .setContentIntent(pendingIntent)
                    .setPriority(Notification.PRIORITY_LOW)
                    .addAction(muteIcon, muteLabel, mutePending)
                    .addAction(R.drawable.ic_disconnect, "Disconnect", discPending)
                    .build()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        // Keep CPU awake for audio processing
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "teamspeak:keepalive").apply {
            acquire()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "TeamSpeak Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps TeamSpeak running in background"
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        try { tsDisconnect() } catch (_: Exception) {}
        // Don't tear down immediately — the Rust event loop needs time
        // to process the disconnect before Android kills the process.
        // Release builds kill the process much faster than debug builds,
        // so we defer teardown on a background thread.
        Thread {
            Thread.sleep(500)
            try { stopForeground(STOP_FOREGROUND_REMOVE) } catch (_: Exception) {}
            wakeLock?.let { if (it.isHeld) it.release() }
            wakeLock = null
            stopSelf()
        }.start()
        super.onTaskRemoved(rootIntent)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "TeamSpeak"
        val text = intent?.getStringExtra("text") ?: "Connected"
        val inputMuted = intent?.getBooleanExtra("input_muted", false) ?: false
        val notification = buildNotification(this, title, text, inputMuted)
        val hasMic = intent?.getBooleanExtra("mic", false) ?: false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            if (hasMic) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            startForeground(NOTIFICATION_ID, notification, types)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
