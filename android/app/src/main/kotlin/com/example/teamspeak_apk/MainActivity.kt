package com.example.teamspeak_apk

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    private var audioRecord: AudioRecord? = null
    @Volatile var isRecording = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Mic capture via EventChannel
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.teamspeak_apk/mic")
            .setStreamHandler(MicStreamHandler(this))
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
