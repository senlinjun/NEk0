import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sfx_service.dart';
import 'ts_ffi.dart';

/// Why an imported voice pack was rejected.
enum SfxPackImportError {
  /// The picked file is not a readable zip archive.
  invalidZip,

  /// pack.json is missing, unparsable, or its voice table does not map
  /// event IDs (1–37) to files that exist in the archive.
  invalidManifest,
}

class SfxPackImportException implements Exception {
  SfxPackImportException(this.error);

  final SfxPackImportError error;

  @override
  String toString() => 'SfxPackImportException($error)';
}

/// An imported voice pack: a named set of WAV sounds for channel events.
///
/// Metadata (name, description, voice table) is kept in SharedPreferences;
/// the extracted files live in `<docs>/sfx_packs/<id>/` so they survive
/// restarts without any storage permission.
class SfxPack {
  SfxPack({required this.id, required this.name, required this.description});

  final String id;
  final String name;
  final String description;

  @override
  bool operator ==(Object other) => other is SfxPack && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// Imports, activates and deletes user voice packs.
///
/// A pack is a zip archive containing a `pack.json` manifest and WAV files:
///
/// ```json
/// {
///   "name": "My pack",
///   "description": "About this pack",
///   "sounds": { "11": "connected.wav", "12": "disconnected.wav" }
/// }
/// ```
///
/// The `sounds` table maps channel-event IDs (see [SfxKind]) to file names
/// inside the archive. Kinds without an entry keep the built-in sound.
/// Activating a pack pushes its WAVs into the Rust mixer via
/// `ts_set_sfx_sample`; deactivating restores the built-in set.
class SfxPackService {
  SfxPackService._();

  static const _dirName = 'sfx_packs';
  static const _packsKey = 'sfx_packs';
  static const _metaPrefix = 'sfx_pack_meta_';
  static const _activeKey = 'sfx_active_pack';

  /// Re-applies the active pack into Rust at startup and removes leftovers
  /// from the pre-pack era (per-kind custom WAVs and their names).
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final legacyDir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/sfx',
    );
    if (await legacyDir.exists()) {
      try {
        await legacyDir.delete(recursive: true);
      } catch (e) {
        debugLog('[sfx-pack] legacy cleanup failed: $e');
      }
    }
    for (final key in prefs.getKeys()) {
      if (key.startsWith('sfx_name_')) {
        await prefs.remove(key);
      }
    }

    final active = prefs.getString(_activeKey);
    if (active != null) {
      await _apply(active);
    }
  }

  /// Opens a zip picker, validates and installs the pack. Returns the newly
  /// imported pack, or null when the user cancelled the picker. Throws
  /// [SfxPackImportException] for a rejected archive.
  static Future<SfxPack?> importZip() async {
    PlatformFile? file;
    try {
      file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
    } catch (_) {
      return null;
    }
    if (file == null) return null;

    Uint8List? bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      bytes = null;
    }
    if (bytes == null || bytes.isEmpty) {
      throw SfxPackImportException(SfxPackImportError.invalidZip);
    }
    return importBytes(bytes);
  }

  /// Validates and installs a pack from raw zip bytes (see [importZip]).
  static Future<SfxPack> importBytes(Uint8List bytes) async {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw SfxPackImportException(SfxPackImportError.invalidZip);
    }

    // Resolve by basename so packs exported with a top-level folder also
    // work (e.g. "MyPack/pack.json" instead of "pack.json").
    final files = <String, ArchiveFile>{
      for (final entry in archive)
        if (entry.isFile) _basename(entry.name): entry,
    };
    final manifest = files['pack.json'];
    if (manifest == null) {
      throw SfxPackImportException(SfxPackImportError.invalidZip);
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifest.content as List<int>));
    } catch (_) {
      throw SfxPackImportException(SfxPackImportError.invalidManifest);
    }
    if (decoded is! Map) {
      throw SfxPackImportException(SfxPackImportError.invalidManifest);
    }
    final name = decoded['name'];
    final description = decoded['description'];
    final sounds = decoded['sounds'];
    if (name is! String || name.trim().isEmpty) {
      throw SfxPackImportException(SfxPackImportError.invalidManifest);
    }
    if (description != null && description is! String) {
      throw SfxPackImportException(SfxPackImportError.invalidManifest);
    }
    if (sounds is! Map || sounds.isEmpty) {
      throw SfxPackImportException(SfxPackImportError.invalidManifest);
    }

    // Voice table: event ID -> WAV file name. Every entry must point at a
    // file that actually exists in the archive.
    final table = <int, String>{};
    for (final entry in sounds.entries) {
      final kind = int.tryParse('${entry.key}');
      final fileName = entry.value;
      if (kind == null ||
          !SfxKind.all.contains(kind) ||
          fileName is! String ||
          _basename(fileName) != fileName ||
          fileName.isEmpty) {
        throw SfxPackImportException(SfxPackImportError.invalidManifest);
      }
      if (!files.containsKey(_basename(fileName))) {
        throw SfxPackImportException(SfxPackImportError.invalidManifest);
      }
      table[kind] = _basename(fileName);
    }

    // Content-derived ID: re-importing the same manifest updates the pack
    // in place instead of piling up copies.
    final id = _packId('${name.trim()}\u0000${manifest.content}');
    final dir = await _directoryFor(id);
    await dir.create(recursive: true);
    final manifestFile = File('${dir.path}/pack.json');
    await manifestFile.writeAsBytes(manifest.content as List<int>, flush: true);
    for (final fileName in table.values) {
      final data = files[fileName]!.content as List<int>;
      await File('${dir.path}/$fileName').writeAsBytes(data, flush: true);
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      '$_metaPrefix$id',
      jsonEncode({
        'name': name.trim(),
        'description': description is String ? description : '',
        'sounds': {for (final e in table.entries) '${e.key}': e.value},
      }),
    );
    final ids = prefs.getStringList(_packsKey) ?? <String>[];
    if (!ids.contains(id)) {
      await prefs.setStringList(_packsKey, [...ids, id]);
    }
    return SfxPack(
      id: id,
      name: name.trim(),
      description: description is String ? description : '',
    );
  }

  /// All imported packs in import order.
  static Future<List<SfxPack>> loadPacks() async {
    final prefs = await SharedPreferences.getInstance();
    final packs = <SfxPack>[];
    for (final id in prefs.getStringList(_packsKey) ?? const <String>[]) {
      final pack = _packFromPrefs(prefs, id);
      if (pack != null) packs.add(pack);
    }
    return packs;
  }

  /// ID of the currently active pack, or null when the built-in sounds are
  /// in use.
  static Future<String?> activePackId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey);
  }

  /// Pushes every sound of the pack into Rust and marks it active. Returns
  /// the number of sounds that could not be loaded (bad format or longer
  /// than 2 s); those kinds keep the previously active sample.
  static Future<int> activate(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final failed = await _apply(id);
    await prefs.setString(_activeKey, id);
    return failed;
  }

  /// Restores the built-in sound set.
  static Future<void> deactivate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeKey);
    SfxService.clearAllSamples();
  }

  /// Removes a pack. If it is currently active, the built-in sound set is
  /// restored first.
  static Future<void> delete(String id) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_activeKey) == id) {
      await deactivate();
    }
    await prefs.setStringList(
      _packsKey,
      (prefs.getStringList(_packsKey) ?? const <String>[])
          .where((e) => e != id)
          .toList(),
    );
    await prefs.remove('$_metaPrefix$id');
    final dir = Directory(
      '${(await getApplicationDocumentsDirectory()).path}/$_dirName/$id',
    );
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        debugLog('[sfx-pack] delete $id failed: $e');
      }
    }
  }

  /// Pushes the pack's samples into Rust. Returns the number of failures.
  static Future<int> _apply(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final meta = _packFromPrefs(prefs, id);
    if (meta == null) return 0;
    final sounds = await _soundsOf(prefs, id);
    var failed = 0;
    for (final entry in sounds.entries) {
      try {
        final bytes = await File(
          '${(await _directoryFor(id)).path}/${entry.value}',
        ).readAsBytes();
        if (bytes.isEmpty || SfxService.setSample(entry.key, bytes) != 0) {
          failed++;
        }
      } catch (_) {
        failed++;
      }
    }
    return failed;
  }

  static Future<Map<int, String>> _soundsOf(
    SharedPreferences prefs,
    String id,
  ) async {
    final raw = prefs.getString('$_metaPrefix$id');
    if (raw == null) return const {};
    final map = <int, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['sounds'] is Map) {
        for (final entry in (decoded['sounds'] as Map).entries) {
          final kind = int.tryParse('${entry.key}');
          if (kind != null && entry.value is String) {
            map[kind] = entry.value as String;
          }
        }
      }
    } catch (_) {}
    return map;
  }

  static SfxPack? _packFromPrefs(SharedPreferences prefs, String id) {
    final raw = prefs.getString('$_metaPrefix$id');
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['name'] is String) {
        return SfxPack(
          id: id,
          name: decoded['name'] as String,
          description: decoded['description'] is String
              ? decoded['description'] as String
              : '',
        );
      }
    } catch (_) {}
    return null;
  }

  static Future<Directory> _directoryFor(String id) async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/$_dirName/$id');
  }

  /// Dual 32-bit FNV-1a (forward + reversed) over [data], as 16 lowercase
  /// hex digits. 32-bit lanes keep every intermediate product below 2^63,
  /// so there are no signed-int wraparound quirks to worry about.
  static String _packId(String data) {
    final bytes = utf8.encode(data);
    var forward = 0x811c9dc5;
    var reversed = 0x811c9dc5;
    for (final byte in bytes) {
      forward = ((forward ^ byte) * 0x01000193) & 0xFFFFFFFF;
    }
    for (var i = bytes.length - 1; i >= 0; i--) {
      reversed = ((reversed ^ bytes[i]) * 0x01000193) & 0xFFFFFFFF;
    }
    return forward.toRadixString(16).padLeft(8, '0') +
        reversed.toRadixString(16).padLeft(8, '0');
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }
}
