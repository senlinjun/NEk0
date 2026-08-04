package com.senlinjun.nek0

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class KeepAliveService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var mediaSession: MediaSession? = null

    companion object {
        const val CHANNEL_ID = "teamspeak_keepalive"
        const val NOTIFICATION_ID = 1

        /// App icon used as the media card artwork. Loaded once on service
        /// start and cached to avoid decoding it on every notification update.
        @JvmField var cachedArtwork: Bitmap? = null

        init {
            try { System.loadLibrary("tsclient") } catch (_: Exception) {}
        }

        @JvmStatic external fun tsDisconnect()

        // Stored for NotificationActionReceiver to rebuild notification after actions
        @JvmField var lastTitle: String = "TeamSpeak"
        @JvmField var lastText: String = "Connected"
        @JvmField var lastInputMuted: Boolean = false
        @JvmField var lastMuteLabel: String = "Mute"
        @JvmField var lastUnmuteLabel: String = "Unmute"
        @JvmField var lastDisconnectLabel: String = "Disconnect"

        fun start(
            context: Context,
            title: String,
            text: String,
            mic: Boolean = false,
            inputMuted: Boolean = false,
            muteLabel: String = "Mute",
            unmuteLabel: String = "Unmute",
            disconnectLabel: String = "Disconnect",
        ) {
            lastTitle = title
            lastText = text
            lastInputMuted = inputMuted
            lastMuteLabel = muteLabel
            lastUnmuteLabel = unmuteLabel
            lastDisconnectLabel = disconnectLabel
            val intent = Intent(context, KeepAliveService::class.java).apply {
                putExtra("title", title)
                putExtra("text", text)
                putExtra("mic", mic)
                putExtra("input_muted", inputMuted)
                putExtra("mute_label", muteLabel)
                putExtra("unmute_label", unmuteLabel)
                putExtra("disconnect_label", disconnectLabel)
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

        fun update(
            context: Context,
            title: String,
            text: String,
            mic: Boolean = false,
            inputMuted: Boolean = false,
            muteLabel: String = "Mute",
            unmuteLabel: String = "Unmute",
            disconnectLabel: String = "Disconnect",
        ) {
            lastTitle = title
            lastText = text
            lastInputMuted = inputMuted
            lastMuteLabel = muteLabel
            lastUnmuteLabel = unmuteLabel
            lastDisconnectLabel = disconnectLabel
            // Restart service to update foreground service type (Android 14+)
            val serviceIntent = Intent(context, KeepAliveService::class.java).apply {
                putExtra("title", title)
                putExtra("text", text)
                putExtra("mic", mic)
                putExtra("input_muted", inputMuted)
                putExtra("mute_label", muteLabel)
                putExtra("unmute_label", unmuteLabel)
                putExtra("disconnect_label", disconnectLabel)
            }
            context.startService(serviceIntent)
        }

        @JvmStatic
        fun buildNotification(
            context: Context,
            title: String,
            text: String,
            inputMuted: Boolean = false,
            sessionToken: MediaSession.Token? = null,
            muteLabel: String = lastMuteLabel,
            unmuteLabel: String = lastUnmuteLabel,
            disconnectLabel: String = lastDisconnectLabel,
        ): Notification {
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
            val muteActionLabel = if (inputMuted) unmuteLabel else muteLabel

            val mediaStyle = Notification.MediaStyle().setShowActionsInCompactView(0)
            // Attach the media session token so the notification renders as media
            // controls and the system recognizes the active playback. Note:
            // Notification has no setMediaSession() — the token only attaches
            // via MediaStyle.setMediaSession() on the Builder.
            if (sessionToken != null) mediaStyle.setMediaSession(sessionToken)

            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(R.drawable.ic_stat_mic)
                    .setOngoing(true)
                    .setContentIntent(pendingIntent)
                    .setStyle(mediaStyle)
                    .addAction(muteIcon, muteActionLabel, mutePending)
                    .addAction(R.drawable.ic_disconnect, disconnectLabel, discPending)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(R.drawable.ic_stat_mic)
                    .setOngoing(true)
                    .setContentIntent(pendingIntent)
                    .setPriority(Notification.PRIORITY_LOW)
                    .addAction(muteIcon, muteActionLabel, mutePending)
                    .addAction(R.drawable.ic_disconnect, disconnectLabel, discPending)
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
        cachedArtwork = loadAppIcon()
        // Register a media session in the playing state so the system treats
        // this app as a real media app. Without it, Android 14+ (especially
        // Android 15's 6h/24h mediaPlayback limit) stops the foreground
        // service after a while in the background, killing the process.
        mediaSession = MediaSession(this, "NEk0").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    // Media card "play" = restore: unmute input+output, mic on.
                    invokeDart("set_full_mute", mapOf("muted" to false))
                }

                override fun onPause() {
                    // Media card "pause" = full mute: input+output muted, mic off.
                    invokeDart("set_full_mute", mapOf("muted" to true))
                }
            })
            setPlaybackState(
                PlaybackState.Builder()
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1f)
                    // Keep the play/pause action so the media card shows the
                    // button that drives the full-mute toggle via onPlay/onPause.
                    .setActions(PlaybackState.ACTION_PLAY_PAUSE)
                    .build()
            )
            setMetadata(buildMetadata(lastTitle, lastText))
            setActive(true)
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

    private fun buildMetadata(title: String, text: String): MediaMetadata =
        MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, text)
            .apply {
                cachedArtwork?.let {
                    // ARTWORK: card art on older Android; DISPLAY_ICON:
                    // the icon slot of the Android 13+ media card. Both are
                    // needed so the card is never an empty placeholder.
                    putBitmap(MediaMetadata.METADATA_KEY_ARTWORK, it)
                    putBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON, it)
                }
            }
            .build()

    /// The launcher icon as a bitmap for the media card (no extra assets).
    /// Handles both plain bitmap icons and adaptive icons (API 26+).
    private fun loadAppIcon(): Bitmap? {
        return try {
            val icon = packageManager.getApplicationIcon(packageName)
            if (icon is BitmapDrawable) {
                icon.bitmap
            } else {
                val size = icon.intrinsicWidth.takeIf { it > 0 } ?: 192
                val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                icon.setBounds(0, 0, size, size)
                icon.draw(canvas)
                bmp
            }
        } catch (_: Exception) {
            null
        }
    }

    /// Send a platform-channel call into the cached Flutter engine (same
    /// mechanism as NotificationActionReceiver). No-op if the engine is gone.
    private fun invokeDart(method: String, args: Map<String, Any>) {
        val engine = FlutterEngineCache.getInstance().get("teamspeak_engine") ?: return
        try {
            MethodChannel(engine.dartExecutor.binaryMessenger, "com.senlinjun.nek0/service")
                .invokeMethod(method, args)
        } catch (_: Exception) {}
    }

    private fun stopMediaSession() {
        mediaSession?.let {
            it.setPlaybackState(
                PlaybackState.Builder()
                    .setState(PlaybackState.STATE_NONE, 0L, 0f)
                    .build()
            )
            it.setActive(false)
            it.release()
        }
        mediaSession = null
    }

    override fun onDestroy() {
        stopMediaSession()
        wakeLock?.let {
            if (it.isHeld) it.release()
        }
        wakeLock = null
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        try { tsDisconnect() } catch (_: Exception) {}
        stopMediaSession()
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
        val muteLabel = intent?.getStringExtra("mute_label") ?: lastMuteLabel
        val unmuteLabel = intent?.getStringExtra("unmute_label") ?: lastUnmuteLabel
        val disconnectLabel = intent?.getStringExtra("disconnect_label") ?: lastDisconnectLabel
        val notification = buildNotification(
            this, title, text, inputMuted, mediaSession?.sessionToken,
            muteLabel, unmuteLabel, disconnectLabel,
        )
        val hasMic = intent?.getBooleanExtra("mic", false) ?: false
        // Keep the session "playing" and metadata in sync on every update.
        mediaSession?.let {
            it.setMetadata(buildMetadata(title, text))
            it.setPlaybackState(
                PlaybackState.Builder()
                    .setState(PlaybackState.STATE_PLAYING, 0L, 1f)
                    .setActions(PlaybackState.ACTION_PLAY_PAUSE)
                    .build()
            )
            it.setActive(true)
        }
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
