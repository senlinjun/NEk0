import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:math' show sqrt;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ts_ffi.dart';

/// Mic capture plumbing per platform:
/// - Android: Kotlin AudioRecord → EventChannel → Dart → ts_send_audio
///   (keeps the system AEC and the existing permission flow untouched).
/// - Windows / Linux: cpal input stream inside the Rust core
///   (`ts_set_mic_capture`); VAD, gain and Opus encoding are shared, and
///   Dart only polls `ts_get_mic_rms` for the level meter.
class AudioService {
  static final bool _usesNativeMic = !Platform.isAndroid;

  bool _running = false;
  bool _micActive = false;
  StreamSubscription? _micSubscription;
  Timer? _rmsTimer;

  static const _micChannel = EventChannel('com.senlinjun.nek0/mic');

  bool get isRunning => _running;

  double _micRms = 0.0;
  double get micRms => _micRms;
  void Function(double rms)? onMicLevel;

  /// Fired when native capture reports a failure — a failed start or an
  /// error on a running stream. Desktop (cpal) path only; the payload is
  /// the raw native error text (classify with mic_error.dart for display).
  void Function(String error)? onMicError;

  /// Last error text already reported, so the 50ms poll loop only fires
  /// onMicError on change instead of 20x per second.
  String _lastReportedError = '';

  /// Reads the native last-error and fires [onMicError] when it changed.
  void _reportMicError() {
    final err = TsNative.getLastAudioError();
    if (err.isNotEmpty && err != _lastReportedError) {
      _lastReportedError = err;
      onMicError?.call(err);
    }
  }

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
    if (_micActive) return true;
    try {
      var granted = true;
      if (Platform.isAndroid) {
        // Used for the foreground-service notification; harmless to ask
        // once alongside the mic permission (Android-only UX).
        await Permission.notification.request();
        final status = await Permission.microphone.request();
        granted = status.isGranted;
      }
      // Windows/Linux: permission_handler has no desktop support — the OS
      // prompts on the first capture attempt. Success is judged by the
      // capture stream itself.
      if (!granted) {
        debugPrint('AudioService: mic permission denied');
        return false;
      }
      if (_usesNativeMic) {
        granted = TsNative.setMicCapture(true);
        if (!granted) {
          debugPrint('AudioService: native mic capture failed');
          // The native side records *why* (device, format, Windows mic
          // privacy…); stderr is invisible in a GUI session, so push it up.
          _reportMicError();
        }
      } else {
        _startAndroidMic();
      }
      if (granted) {
        _micActive = true;
        if (_usesNativeMic) _startRmsPolling();
        debugPrint('AudioService: mic enabled');
      } else if (_usesNativeMic) {
        // Keep polling even on failure: it surfaces the current error to
        // the UI and picks up a later-resolved blocker (e.g. the user
        // flipping on the Windows microphone-privacy switch) while the
        // caller's retry loop keeps re-attempting.
        _startRmsPolling();
      }
      return granted;
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

  // ─── Android: EventChannel push from Kotlin AudioRecord ──────────

  void _startAndroidMic() {
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

  // ─── Native capture (iOS / desktop): RMS polling ─────────────────

  void _startRmsPolling() {
    _rmsTimer?.cancel();
    _rmsTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (_micActive) {
        final rms = TsNative.getMicRms();
        _micRms = rms;
        onMicLevel?.call(rms);
        // A stream that built fine can still die mid-session (device
        // unplug, WASAPI glitch) — only the native error reports it.
      }
      _reportMicError();
    });
  }

  void _stopMic() {
    if (_usesNativeMic) {
      if (_micActive) TsNative.setMicCapture(false);
    } else {
      _micSubscription?.cancel();
      _micSubscription = null;
    }
    _rmsTimer?.cancel();
    _rmsTimer = null;
    _micActive = false;
    _micRms = 0.0;
    _lastReportedError = '';
  }
}
