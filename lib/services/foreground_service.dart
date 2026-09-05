import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Android platform-channel facade (foreground service, notification
/// actions, MediaStore downloads). On iOS / desktop every method degrades to
/// a no-op except [saveToDownloads], which has real per-platform
/// implementations below.
class ForegroundService {
  static const _channel = MethodChannel('com.senlinjun.nek0/service');

  static bool get _isAndroid => Platform.isAndroid;

  /// Callbacks invoked by notification action buttons (BroadcastReceiver →
  /// FlutterEngine → MethodChannel → here). Wired in ts_state.dart.
  static void Function(bool inputMuted)? onToggleMute;
  static void Function(bool away, bool muted)? onSetAwayMute;
  static VoidCallback? onNotificationDisconnect;

  static void init() {
    // The inbound notification-action channel only exists on Android.
    if (!_isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'toggle_mute':
          final args = call.arguments as Map?;
          final inputMuted = (args?['input_muted'] as bool?) ?? false;
          onToggleMute?.call(inputMuted);
          break;
        case 'set_away_full_mute':
          final args = call.arguments as Map?;
          final away = (args?['away'] as bool?) ?? false;
          final muted = (args?['muted'] as bool?) ?? false;
          onSetAwayMute?.call(away, muted);
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
    bool fullMuted = false,
    String muteLabel = 'Mute',
    String unmuteLabel = 'Unmute',
    String disconnectLabel = 'Disconnect',
  }) async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod('start', {
        'title': title,
        'text': text,
        'mic': mic,
        'input_muted': inputMuted,
        'full_muted': fullMuted,
        'mute_label': muteLabel,
        'unmute_label': unmuteLabel,
        'disconnect_label': disconnectLabel,
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
    bool fullMuted = false,
    String muteLabel = 'Mute',
    String unmuteLabel = 'Unmute',
    String disconnectLabel = 'Disconnect',
  }) async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod('update', {
        'title': title,
        'text': text,
        'mic': mic,
        'input_muted': inputMuted,
        'full_muted': fullMuted,
        'mute_label': muteLabel,
        'unmute_label': unmuteLabel,
        'disconnect_label': disconnectLabel,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> stop() async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod('stop');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Ask the system to exempt the app from battery optimization
  /// (same trick music players use to stay alive in the background).
  /// Returns true if already exempt. Android-only.
  static Future<bool> requestBatteryOptimizationExemption() async {
    if (!_isAndroid) return false;
    try {
      final result = await _channel.invokeMethod(
        'request_battery_optimization_exemption',
      );
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Show a system notification for an incoming poke. Android-only (other
  /// platforms surface pokes inside the app).
  static Future<void> notifyPoke({
    required String title,
    required String body,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('notify_poke', {
        'title': title,
        'body': body,
      });
    } catch (e) {
      // Notifications are best-effort; never crash the poll loop.
    }
  }

  /// Copies a finished download into a user-visible location:
  /// - Android: shared Downloads collection (MediaStore on 10+, app-private
  ///   fallback folder below).
  /// - Windows / Linux: the system Downloads directory.
  /// Returns a user-facing destination description, or null on failure.
  static Future<String?> saveToDownloads({
    required String srcPath,
    required String displayName,
    String? relativeDir,
  }) async {
    try {
      if (Platform.isAndroid) {
        final result = await _channel.invokeMethod('save_to_downloads', {
          'src_path': srcPath,
          'display_name': displayName,
          if (relativeDir != null && relativeDir.isNotEmpty)
            'relative_dir': relativeDir,
        });
        if (result is Map) {
          return (result['destination'] as String?) ?? '';
        }
        return null;
      }

      final downloads = await getDownloadsDirectory();
      if (downloads == null) return null;
      final segments = <String>[downloads.path];
      for (final s in (relativeDir ?? 'NEk0').split('/')) {
        if (s.isNotEmpty && s != '.' && s != '..') segments.add(s);
      }
      segments.add(_freeFileName(Directory(segments.join('/')), displayName));
      final destPath = segments.join('/');
      await Directory(
        segments.sublist(0, segments.length - 1).join('/'),
      ).create(recursive: true);
      await File(srcPath).copy(destPath);
      return destPath;
    } catch (e) {
      debugPrint('ForegroundService: saveToDownloads failed: $e');
      return null;
    }
  }

  /// Returns [displayName], or a "name (2).ext" variant when the target
  /// already exists (the Android MediaStore path resolves collisions inside
  /// the Kotlin side; desktop handles it here).
  static String _freeFileName(Directory dir, String displayName) {
    final dot = displayName.lastIndexOf('.');
    final stem = dot > 0 ? displayName.substring(0, dot) : displayName;
    final ext = dot > 0 ? displayName.substring(dot) : '';
    var candidate = displayName;
    var n = 2;
    while (File('${dir.path}/$candidate').existsSync()) {
      candidate = '$stem ($n)$ext';
      n += 1;
    }
    return candidate;
  }
}
