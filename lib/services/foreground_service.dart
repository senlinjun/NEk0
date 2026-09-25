import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

/// Platform-channel facade (Android foreground service, notification
/// actions, MediaStore downloads). On iOS every method degrades to a no-op;
/// desktop gets [saveToDownloads] (system Downloads directory) and
/// [notify] (system toasts), everything else is a no-op.
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

  /// Test seam — set to intercept the platform launch.
  @visibleForTesting
  static Future<void> Function(String title, String body)? notifyOverride;

  /// Show a system notification. Android posts it through the platform
  /// service channel; desktop apps show a system toast via local_notifier
  /// (Windows WinRT / Linux libnotify). Best-effort — failures are
  /// swallowed so the poll loop never crashes (e.g. a Linux session
  /// without a notification daemon).
  static Future<void> notify({
    required String title,
    required String body,
  }) async {
    final override = notifyOverride;
    if (override != null) {
      await override(title, body);
      return;
    }
    try {
      if (_isAndroid) {
        await _channel.invokeMethod('notify', {'title': title, 'body': body});
      } else {
        final notification = LocalNotification(title: title, body: body);
        // Clicking the toast brings the app window back up.
        notification.onClick = () {
          windowManager.show();
          windowManager.focus();
        };
        await notification.show();
      }
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

  // ─── User-picked recordings directory ─────────────────────────────

  /// Lets the user pick the recordings save directory. Android: SAF directory
  /// tree (persisted permission, returns a tree URI string). Desktop: system
  /// directory dialog (returns an absolute path). Null = cancelled/failed.
  static Future<String?> pickSaveDir() async {
    try {
      final result = await _channel.invokeMethod('pick_save_dir');
      return result as String?;
    } catch (e) {
      debugPrint('ForegroundService: pickSaveDir failed: $e');
      return null;
    }
  }

  /// Copies [srcPath] into the SAF directory tree the user picked earlier
  /// ([treeUri] as returned by [pickSaveDir]), inside the [subDir] per-save
  /// subfolder when given (created on demand). Returns a user-facing
  /// destination description ("<folder>/<sub>/<file>"), or null on failure.
  static Future<String?> saveToPickedDir({
    required String srcPath,
    required String displayName,
    required String treeUri,
    String? subDir,
  }) async {
    try {
      final result = await _channel.invokeMethod('save_to_saf', {
        'src_path': srcPath,
        'display_name': displayName,
        'tree_uri': treeUri,
        if (subDir != null && subDir.isNotEmpty) 'sub_dir': subDir,
      });
      if (result is Map) {
        return (result['destination'] as String?) ?? '';
      }
      return null;
    } catch (e) {
      debugPrint('ForegroundService: saveToPickedDir failed: $e');
      return null;
    }
  }

  /// Copies [srcPath] into a user-chosen directory (desktop). Collisions
  /// resolved with the same "name (2).ext" scheme as [saveToDownloads].
  /// Returns the full destination path, or null on failure.
  static Future<String?> saveToCustomDir({
    required String srcPath,
    required String displayName,
    required String dir,
  }) async {
    try {
      final d = Directory(dir);
      await d.create(recursive: true);
      final destPath = '${d.path}/${_freeFileName(d, displayName)}';
      await File(srcPath).copy(destPath);
      return destPath;
    } catch (e) {
      debugPrint('ForegroundService: saveToCustomDir failed: $e');
      return null;
    }
  }
}
