import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Picks, stores and removes the user-custom background image.
///
/// Mirrors [SfxService]: the picked image is copied into the app's private
/// documents directory (`<docs>/background/custom.<ext>`) so it survives
/// restarts without any storage permission (the file picker uses SAF). The
/// absolute path is persisted in SharedPreferences and rendered app-wide by
/// the background layer in main.dart.
class BackgroundService {
  BackgroundService._();

  static const _bgDir = 'background';
  static const _pathKey = 'custom_bg_path';
  static const _nameKey = 'custom_bg_name';
  static const _allowedExtensions = {'jpg', 'jpeg', 'png', 'webp'};

  static Future<Directory> _directory() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_bgDir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Opens the image picker, copies the chosen file into the private
  /// documents directory and persists its path. Returns the stored absolute
  /// path, or null when the user cancelled or the pick failed (the previous
  /// background, if any, stays in place).
  static Future<String?> pickAndStore() async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(type: FileType.image);
    } catch (_) {
      return null; // cancelled, or the picker itself failed
    }
    if (file == null) return null;
    Uint8List bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return null;
    }
    if (bytes.isEmpty) return null;

    // file_picker v12 has no PlatformFile.extension — take it from the name.
    final name = file.name;
    final dot = name.lastIndexOf('.');
    final rawExt = dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
    final ext = _allowedExtensions.contains(rawExt) ? rawExt : 'jpg';
    final dir = await _directory();
    // Remove any previous custom image (its extension may differ).
    for (final entity in await dir.list().toList()) {
      if (entity is File && entity.path.startsWith('${dir.path}/custom.')) {
        try {
          await entity.delete();
        } catch (_) {
          // Stale files are harmless — the new one simply sits beside them.
        }
      }
    }
    final target = File('${dir.path}/custom.$ext');
    await target.writeAsBytes(bytes, flush: true);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pathKey, target.path);
    await prefs.setString(
      _nameKey,
      file.name.isNotEmpty ? file.name : 'custom.$ext',
    );
    return target.path;
  }

  /// Deletes the stored image and forgets the persisted path and name.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_pathKey);
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {
        // A file that cannot be deleted must not block clearing the setting;
        // main.dart renders nothing once the path is gone from prefs.
      }
    }
    await prefs.remove(_pathKey);
    await prefs.remove(_nameKey);
  }

  /// Display name of the current custom image, or null when none is set.
  static Future<String?> customName() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(_nameKey);
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return (await prefs.getString(_pathKey) != null) ? 'custom' : null;
  }
}
