package com.senlinjun.nek0

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.app.PendingIntent
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    companion object {
        init {
            // Load the native library at app start so tsInitAndroid can bind
            // before anything else. KeepAliveService loads it again later,
            // which is a no-op.
            try { System.loadLibrary("tsclient") } catch (_: Exception) {}
        }
    }

    // Hands the JVM + application context to the Rust audio stack
    // (ndk-context). cpal/oboe need it to build streams on Android; it must
    // be initialized before the first connection, so it runs at the very top
    // of onCreate.
    private external fun tsInitAndroid(context: Context)

    override fun onCreate(savedInstanceState: Bundle?) {
        tsInitAndroid(applicationContext)
        super.onCreate(savedInstanceState)
    }

    private var audioRecord: AudioRecord? = null
    @Volatile var isRecording = false

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        val cacheKey = "teamspeak_engine"
        var engine = FlutterEngineCache.getInstance().get(cacheKey)
        if (engine == null) {
            engine = FlutterEngine(context)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault()
            )
            FlutterEngineCache.getInstance().put(cacheKey, engine)
        }
        return engine
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Mic capture via EventChannel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.senlinjun.nek0/mic")
            .setStreamHandler(MicStreamHandler(this))

        // Foreground service control via MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.senlinjun.nek0/service")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val title = call.argument<String>("title") ?: "TeamSpeak"
                        val text = call.argument<String>("text") ?: "Connected"
                        val mic = call.argument<Boolean>("mic") ?: false
                        val inputMuted = call.argument<Boolean>("input_muted") ?: false
                        val fullMuted = call.argument<Boolean>("full_muted") ?: false
                        val muteLabel = call.argument<String>("mute_label") ?: "Mute"
                        val unmuteLabel = call.argument<String>("unmute_label") ?: "Unmute"
                        val disconnectLabel = call.argument<String>("disconnect_label") ?: "Disconnect"
                        KeepAliveService.start(
                            this, title, text, mic, inputMuted, fullMuted,
                            muteLabel, unmuteLabel, disconnectLabel,
                        )
                        result.success(true)
                    }
                    "stop" -> {
                        KeepAliveService.stop(this)
                        result.success(true)
                    }
                    "update" -> {
                        val title = call.argument<String>("title") ?: "TeamSpeak"
                        val text = call.argument<String>("text") ?: "Connected"
                        val mic = call.argument<Boolean>("mic") ?: false
                        val inputMuted = call.argument<Boolean>("input_muted") ?: false
                        val fullMuted = call.argument<Boolean>("full_muted") ?: false
                        val muteLabel = call.argument<String>("mute_label") ?: "Mute"
                        val unmuteLabel = call.argument<String>("unmute_label") ?: "Unmute"
                        val disconnectLabel = call.argument<String>("disconnect_label") ?: "Disconnect"
                        KeepAliveService.update(
                            this, title, text, mic, inputMuted, fullMuted,
                            muteLabel, unmuteLabel, disconnectLabel,
                        )
                        result.success(true)
                    }
                    "request_battery_optimization_exemption" -> {
                        result.success(requestBatteryOptimizationExemption())
                    }
                    "notify_poke" -> {
                        val title = call.argument<String>("title") ?: "Poke"
                        val body = call.argument<String>("body") ?: ""
                        showPokeNotification(title, body)
                        result.success(true)
                    }
                    "save_to_downloads" -> {
                        val src = call.argument<String>("src_path") ?: ""
                        val name = call.argument<String>("display_name") ?: "file"
                        val relDir = call.argument<String>("relative_dir")
                        result.success(saveToDownloads(src, name, relDir))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Music players stay alive partly because they're exempt from battery
    /// optimization. Ask the system for the same exemption on first connect.
    private fun requestBatteryOptimizationExemption(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val pkg = packageName
        if (pm.isIgnoringBatteryOptimizations(pkg)) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$pkg")
                )
            )
            false
        } catch (_: Exception) {
            false
        }
    }

    /// Show a system notification for an incoming poke. Uses an
    /// IMPORTANCE_HIGH channel so it pops up even in the background; falls
    /// back to a default channel on very old platforms.
    @SuppressLint("MissingPermission")
    private fun showPokeNotification(title: String, body: String) {
        try {
            val pm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channelId = "teamspeak_poke"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    channelId,
                    "Pokes",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Incoming pokes"
                }
                pm.createNotificationChannel(channel)
            }
            val launchIntent = packageManager
                .getLaunchIntentForPackage(packageName)
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            val contentIntent = PendingIntent.getActivity(this, 0, launchIntent, flags)
            val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setSmallIcon(R.drawable.ic_stat_mic)
                    .setAutoCancel(true)
                    .setContentIntent(contentIntent)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
                    .setContentTitle(title)
                    .setContentText(body)
                    .setSmallIcon(R.drawable.ic_stat_mic)
                    .setAutoCancel(true)
                    .setContentIntent(contentIntent)
                    .build()
            }
            pm.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), notification)
        } catch (_: Exception) {
            // Best-effort: a poke notification must never crash the app.
        }
    }

    /// Copies a finished download into the shared Downloads collection.
    /// Android 10+: MediaStore.Downloads with RELATIVE_PATH (no permission
    /// needed). Below that: the app-private downloads folder as fallback —
    /// legacy runtime storage permissions are deliberately not requested.
    /// Returns a map {ok, destination} for user-facing feedback.
    private fun saveToDownloads(srcPath: String, displayName: String, relativeDir: String?): Map<String, Any> {
        val src = java.io.File(srcPath)
        if (!src.exists() || !src.isFile) {
            return mapOf("ok" to false)
        }
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Sanitize the sub path against traversal out of Download/.
                val safeDir = relativeDir
                    ?.trim('/')
                    ?.replace("..", "_")
                    ?.takeIf { it.isNotBlank() }
                val values = android.content.ContentValues().apply {
                    put(android.provider.MediaStore.Downloads.DISPLAY_NAME, displayName)
                    if (safeDir != null) {
                        put(
                            android.provider.MediaStore.Downloads.RELATIVE_PATH,
                            "Download/$safeDir"
                        )
                    } else {
                        put(android.provider.MediaStore.Downloads.RELATIVE_PATH, "Download")
                    }
                }
                val resolver = contentResolver
                val uri = resolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: return mapOf("ok" to false)
                resolver.openOutputStream(uri)?.use { out ->
                    src.inputStream().use { it.copyTo(out) }
                } ?: return mapOf("ok" to false)
                mapOf("ok" to true, "destination" to "Download/${if (safeDir != null) "$safeDir/" else ""}$displayName")
            } else {
                // Pre-Q fallback: app-private external files dir.
                val dir = java.io.File(getExternalFilesDir(null), "Downloads").apply { mkdirs() }
                val target = java.io.File(dir, displayName)
                src.copyTo(target, overwrite = true)
                mapOf("ok" to true, "destination" to target.absolutePath)
            }
        } catch (_: Exception) {
            mapOf("ok" to false)
        }
    }

    fun startMic(): Boolean {
        if (isRecording) return true
        val sampleRate = 48000
        val bufferSize = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT,
        )
        if (bufferSize == AudioRecord.ERROR || bufferSize == AudioRecord.ERROR_BAD_VALUE) {
            return false
        }

        val record = AudioRecord(
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT,
            bufferSize * 2,
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            return false
        }

        audioRecord = record
        record.startRecording()
        isRecording = true
        return true
    }

    fun stopMic() {
        isRecording = false
        audioRecord?.let {
            it.stop()
            it.release()
        }
        audioRecord = null
    }

    fun readMicBuffer(): FloatArray? {
        val record = audioRecord ?: return null
        if (!isRecording) return null
        val frameSize = 960 // 20ms at 48kHz
        val buf = FloatArray(frameSize)
        val read = record.read(buf, 0, frameSize, AudioRecord.READ_NON_BLOCKING)
        if (read <= 0) return null
        return if (read < frameSize) buf.copyOf(read) else buf
    }
}

class MicStreamHandler(private val activity: MainActivity) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private var thread: Thread? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        if (activity.startMic()) {
            thread = Thread {
                while (activity.isRecording) {
                    val data = activity.readMicBuffer()
                    if (data != null) {
                        // Use LITTLE_ENDIAN to match Dart Float32List on ARM
                        val bb = ByteBuffer.allocate(data.size * 4)
                            .order(ByteOrder.LITTLE_ENDIAN)
                        bb.asFloatBuffer().put(data)
                        activity.runOnUiThread {
                            sink?.success(bb.array())
                        }
                    } else {
                        Thread.sleep(10)
                    }
                }
            }.also { it.start() }
        }
    }

    override fun onCancel(arguments: Any?) {
        activity.stopMic()
        sink = null
        thread = null
    }
}
