import 'dart:async';
import 'dart:ffi';
import 'dart:math' show sqrt;
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ts_ffi.dart';

class AudioService {
  bool _running = false;
  StreamSubscription? _micSubscription;

  static const _micChannel = EventChannel('com.senlinjun.nek0/mic');

  bool get isRunning => _running;

  double _micRms = 0.0;
  double get micRms => _micRms;
  void Function(double rms)? onMicLevel;

  Future<bool> start() async {
    if (_running) return true;

    if (!TsNative.startAudio()) {
      debugPrint('AudioService: startAudio failed');
      return false;
    }

    _running = true;
    debugPrint('AudioService: started (mic not yet active)');
    return true;
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
    var sumSq = 0.0;
    for (int i = 0; i < floatCount; i++) {
      final s = bd.getFloat32(i * 4, Endian.little);
      floats[i] = s;
      sumSq += s * s;
    }
    _micRms = sqrt(sumSq / floatCount);
    onMicLevel?.call(_micRms);
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
