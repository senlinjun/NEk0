import 'package:flutter/services.dart';

class ForegroundService {
  static const _channel = MethodChannel('com.senlinjun.nek0/service');

  /// Callbacks invoked by notification action buttons (BroadcastReceiver →
  /// FlutterEngine → MethodChannel → here). Wired in ts_state.dart.
  static void Function(bool inputMuted)? onToggleMute;
  static VoidCallback? onNotificationDisconnect;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'toggle_mute':
          final args = call.arguments as Map?;
          final inputMuted = (args?['input_muted'] as bool?) ?? false;
          onToggleMute?.call(inputMuted);
          break;
        case 'disconnect':
          onNotificationDisconnect?.call();
          break;
      }
    });
  }

  static Future<bool> start({
    String title = 'TeamSpeak',
    String text = 'Connected',
    bool mic = false,
    bool inputMuted = false,
  }) async {
    try {
      final result = await _channel.invokeMethod('start', {
        'title': title,
        'text': text,
        'mic': mic,
        'input_muted': inputMuted,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> update({
    String title = 'TeamSpeak',
    String text = 'Connected',
    bool mic = false,
    bool inputMuted = false,
  }) async {
    try {
      final result = await _channel.invokeMethod('update', {
        'title': title,
        'text': text,
        'mic': mic,
        'input_muted': inputMuted,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> stop() async {
    try {
      final result = await _channel.invokeMethod('stop');
      return result == true;
    } catch (e) {
      return false;
    }
  }
}
