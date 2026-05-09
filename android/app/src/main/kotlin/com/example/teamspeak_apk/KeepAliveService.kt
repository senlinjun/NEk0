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

        fun start(context: Context, title: String, text: String) {
            val intent = Intent(context, KeepAliveService::class.java).apply {
                putExtra("title", title)
                putExtra("text", text)
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

        fun update(context: Context, title: String, text: String) {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(context, title, text))
        }

        private fun buildNotification(context: Context, title: String, text: String): Notification {
            val launchIntent = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val pendingIntent = PendingIntent.getActivity(context, 0, launchIntent, flags)

            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setOngoing(true)
                    .setContentIntent(pendingIntent)
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
        stopForeground(STOP_FOREGROUND_REMOVE)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "TeamSpeak"
        val text = intent?.getStringExtra("text") ?: "Connected"
        val notification = buildNotification(this, title, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK or
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
