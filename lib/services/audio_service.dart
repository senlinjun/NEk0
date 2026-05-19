import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data'
    show ByteData, Endian, Float, Float32List, Uint8List;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ts_ffi.dart';

class AudioService {
  bool _running = false;
  bool _playbackRunning = false;
  StreamSubscription? _micSubscription;

  static const _micChannel = EventChannel('com.senlinjun.nek0/mic');
  static const int _frameSize = 960; // 20ms at 48kHz mono

  bool get isRunning => _running;

  Future<bool> start() async {
    if (_running) return true;

    if (!TsNative.startAudio()) {
      debugPrint('AudioService: startAudio failed');
      return false;
    }

    _running = true;
    debugPrint('AudioService: started (mic not yet active)');

    // Start playback immediately — always listening
    _startPlayback();

    return true;
  }

  // ─── Playback ────────────────────────────────────────────────────

  Future<void> _startPlayback() async {
    if (_playbackRunning) return;
    try {
      await FlutterPcmSound.setup(sampleRate: 48000, channelCount: 1);
      // Feed threshold: 960 frames (20ms). Low enough for real-time feel
      // but avoids callback storms.
      await FlutterPcmSound.setFeedThreshold(960);
      FlutterPcmSound.setFeedCallback(_onPlaybackFeed);
      _playbackRunning = true;
      FlutterPcmSound.start(); // triggers _onPlaybackFeed(0) to kick things off
      debugPrint('AudioService: playback started');
    } catch (e) {
      debugPrint('AudioService: playback setup error: $e');
    }
  }

  void _onPlaybackFeed(int remainingFrames) {
    if (!_playbackRunning) return;

    final buf = calloc<Int16>(_frameSize);
    try {
      final got = TsNative.getAudio(buf, _frameSize);
      if (got > 0) {
        final samples = List<int>.generate(got, (i) => buf[i]);
        FlutterPcmSound.feed(PcmArrayInt16.fromList(samples));
      } else {
        // No audio from Rust — feed silence to prevent AudioTrack underrun
        FlutterPcmSound.feed(PcmArrayInt16.zeros(count: _frameSize));
      }
    } catch (e) {
      debugPrint('AudioService: playback feed error: $e');
    } finally {
      calloc.free(buf);
    }
  }

  void _stopPlayback() {
    _playbackRunning = false;
    try {
      FlutterPcmSound.release();
    } catch (e) {
      debugPrint('AudioService: playback release error: $e');
    }
    debugPrint('AudioService: playback stopped');
  }

  // ─── Mic ─────────────────────────────────────────────────────────

  Future<bool> enableMic() async {
    try {
      await Permission.notification.request();
      final status = await Permission.microphone.request();
      if (status.isGranted) {
        _startMic();
        debugPrint('AudioService: mic enabled');
        return true;
      } else {
        debugPrint('AudioService: mic permission denied');
        return false;
      }
    } catch (e) {
      debugPrint('AudioService: mic permission error: $e');
      return false;
    }
  }

  void disableMic() {
    _stopMic();
    debugPrint('AudioService: mic disabled');
  }

  void stop() {
    if (!_running) return;
    _running = false;

    _stopMic();
    _stopPlayback();
    TsNative.stopAudio();
    debugPrint('AudioService: stopped');
  }

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
