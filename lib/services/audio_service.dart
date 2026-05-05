import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data' show ByteData, Endian, Float32List, Int16List, Uint8List;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ts_ffi.dart';

class AudioService {
  bool _running = false;
  bool _playerSetup = false;
  Timer? _fallbackTimer;
  StreamSubscription? _micSubscription;
  int _totalFed = 0;

  static const int _sampleRate = 48000;
  static const int _channels = 1; // Mono (TeamSpeak OpusVoice is mono)
  static const int _frameSize = 960; // 20ms at 48kHz mono
  static const int _feedThreshold = 960; // Feed when < 960 frames remain

  static const _micChannel = EventChannel('com.example.teamspeak_apk/mic');

  bool get isRunning => _running;

  Future<bool> start() async {
    if (_running) return true;

    if (!TsNative.startAudio()) {
      debugPrint('AudioService: startAudio failed');
      return false;
    }

    try {
      await FlutterPcmSound.setup(
        sampleRate: _sampleRate,
        channelCount: _channels,
      );
      _playerSetup = true;
      FlutterPcmSound.setFeedThreshold(_feedThreshold);
      FlutterPcmSound.setFeedCallback((remainingFrames) {
        debugPrint('AudioService: feedCallback remaining=$remainingFrames');
        _feedAudioFromRust();
      });
      // Kick-start the feed cycle
      FlutterPcmSound.start();
    } catch (e) {
      debugPrint('AudioService: player setup failed: $e');
      TsNative.stopAudio();
      return false;
    }

    _running = true;
    debugPrint('AudioService: started (playback only, mic not yet active)');

    // Fallback timer: poll Rust every 50ms in case feed callback doesn't fire
    _fallbackTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _feedAudioFromRust();
    });

    return true;
  }

  /// Enable microphone capture. Call this separately when user wants to speak.
  Future<void> enableMic() async {
    final status = await Permission.microphone.request();
    if (status.isGranted) {
      _startMic();
      debugPrint('AudioService: mic enabled');
    } else {
      debugPrint('AudioService: mic permission denied — listen-only mode');
    }
  }

  /// Disable microphone capture
  void disableMic() {
    _stopMic();
    debugPrint('AudioService: mic disabled');
  }

  void stop() {
    if (!_running) return;
    _running = false;

    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _stopMic();

    if (_playerSetup) {
      FlutterPcmSound.release();
      _playerSetup = false;
    }
    TsNative.stopAudio();
    debugPrint('AudioService: stopped');
  }

  /// Pull PCM from Rust and feed to audio player
  void _feedAudioFromRust() {
    if (!_running) return;
    final buf = malloc<Float>(_frameSize);
    try {
      final samples = TsNative.getAudio(buf, _frameSize);
      if (samples > 0) {
        final pcm = Int16List(samples);
        double peak = 0.0;
        for (int i = 0; i < samples; i++) {
          double s = buf[i].clamp(-1.0, 1.0);
          if (s.abs() > peak) peak = s.abs();
          pcm[i] = (s * 32767).round();
        }
        _totalFed += samples;
        debugPrint('AudioService: feed $samples samp peak=${peak.toStringAsFixed(4)} total=$_totalFed');
        FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm));
      }
    } catch (e) {
      debugPrint('AudioService: feed error: $e');
    } finally {
      malloc.free(buf);
    }
  }

  // ─── Mic ───────────────────────────────────────────────────────────

  void _startMic() {
    _micSubscription = _micChannel.receiveBroadcastStream().listen(
      (data) {
        if (data is Uint8List && _running) {
          _handleMicData(data);
        }
      },
      onError: (e) {
        debugPrint('AudioService: mic error: $e');
      },
    );
  }

  void _stopMic() {
    _micSubscription?.cancel();
    _micSubscription = null;
  }

  void _handleMicData(Uint8List bytes) {
    final floatCount = bytes.length ~/ 4;
    if (floatCount == 0) return;
    final bd = ByteData.sublistView(bytes);
    final floats = Float32List(floatCount);
    for (int i = 0; i < floatCount; i++) {
      floats[i] = bd.getFloat32(i * 4, Endian.little);
    }
    _sendMicData(floats);
  }

  void _sendMicData(Float32List samples) {
    if (!_running) return;
    final ptr = malloc<Float>(samples.length);
    try {
      for (int i = 0; i < samples.length; i++) {
        ptr[i] = samples[i];
      }
      TsNative.sendAudio(ptr, samples.length);
    } finally {
      malloc.free(ptr);
    }
  }
}
