import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where to look for releases. Both point at the same repo (senlinjun/Nek0);
/// the release tag format is vx.y.z.
enum OtaSource {
  github(
    'GitHub',
    'https://api.github.com/repos/senlinjun/Nek0/releases/latest',
  ),
  gitee(
    'Gitee',
    'https://gitee.com/api/v5/repos/senlinjun/Nek0/releases/latest',
  );

  const OtaSource(this.label, this.apiUrl);

  final String label;
  final String apiUrl;
}

/// A newer release found by [OtaService.checkForUpdate].
class OtaUpdateInfo {
  const OtaUpdateInfo({required this.version, required this.apkUrl});

  /// Release tag, e.g. "v1.2.3".
  final String version;
  final String apkUrl;
}

/// Persistent OTA preferences (SharedPreferences).
class OtaSettings {
  bool enabled = true;
  OtaSource source = OtaSource.github;

  static const _kEnabled = 'ota_enabled';
  static const _kSource = 'ota_source';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(_kEnabled) ?? true;
    source = prefs.getString(_kSource) == 'gitee'
        ? OtaSource.gitee
        : OtaSource.github;
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
  }

  Future<void> setSource(OtaSource value) async {
    source = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kSource,
      value == OtaSource.gitee ? 'gitee' : 'github',
    );
  }
}

class OtaService {
  static final _versionRe = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$');

  /// Fetch the latest release from [source] and return update info if it is
  /// newer than the installed version. Returns null when there is no update
  /// (or on any failure — callers should stay quiet).
  static Future<OtaUpdateInfo?> checkForUpdate(OtaSource source) async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = _parseVersion(info.version);
      final resp = await http
          .get(Uri.parse(source.apiUrl), headers: {'User-Agent': 'NEk0'})
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(resp.body) as Map<String, dynamic>;
      final latest = _parseVersion(json['tag_name'] as String?);
      if (latest == null) return null;
      if (current != null && _cmp(current, latest) >= 0) return null;
      final apkUrl = await _pickAsset(json);
      if (apkUrl == null) return null;
      return OtaUpdateInfo(version: json['tag_name'] as String, apkUrl: apkUrl);
    } catch (_) {
      return null;
    }
  }

  /// Download and install the APK, reporting progress via OtaEvent.
  static Stream<OtaEvent> downloadAndInstall(String apkUrl) {
    return OtaUpdate().execute(apkUrl, destinationFilename: 'nek0_update.apk');
  }

  /// Pick the release asset matching the device ABI (split-per-abi builds),
  /// falling back to the universal APK, then to any .apk.
  static Future<String?> _pickAsset(Map<String, dynamic> release) async {
    final assets = (release['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>();
    if (assets.isEmpty) return null;

    String? urlFor(bool Function(String lowerName) match) {
      for (final a in assets) {
        final name = (a['name'] as String? ?? '').toLowerCase();
        if (match(name)) return a['browser_download_url'] as String?;
      }
      return null;
    }

    String abi = '';
    try {
      abi = (await OtaUpdate().getAbi() ?? '').toLowerCase();
    } catch (_) {}

    if (abi.isNotEmpty) {
      final exact = urlFor((n) => n.contains(abi));
      if (exact != null) return exact;
    }
    final universal = urlFor((n) => n.contains('universal'));
    if (universal != null) return universal;
    return urlFor((n) => n.endsWith('.apk'));
  }

  /// Parse "v1.2.3" / "1.2.3" into [major, minor, patch]; null if malformed.
  static List<int>? _parseVersion(String? tag) {
    if (tag == null) return null;
    final m = _versionRe.firstMatch(tag.trim());
    if (m == null) return null;
    return [
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    ];
  }

  static int _cmp(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }
}

/// "Update available" prompt → on confirm, download with progress dialog and
/// hand off to the system installer.
Future<void> showUpdateDialog(BuildContext context, OtaUpdateInfo info) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text(
        'Update available',
        style: TextStyle(color: Colors.white),
      ),
      content: Text(
        'NEk0 ${info.version} is available.\n\n'
        'Download and install it now?',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Later', style: TextStyle(color: Colors.grey)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(backgroundColor: Colors.blue),
          child: const Text('Update'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await showDownloadProgress(context, info);
}

/// Modal dialog following the download stream; auto-dismisses once the system
/// installer takes over (INSTALLING) or on errors.
Future<void> showDownloadProgress(
  BuildContext context,
  OtaUpdateInfo info,
) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _DownloadProgressDialog(info: info),
  );
}

class _DownloadProgressDialog extends StatefulWidget {
  const _DownloadProgressDialog({required this.info});

  final OtaUpdateInfo info;

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  StreamSubscription<OtaEvent>? _sub;
  double _progress = 0;
  String _status = 'Downloading…';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _sub = OtaService.downloadAndInstall(widget.info.apkUrl).listen(
      (event) {
        if (!mounted) return;
        switch (event.status) {
          case OtaStatus.DOWNLOADING:
            final v = double.tryParse(event.value ?? '') ?? 0;
            setState(() {
              _progress = v;
              _status = 'Downloading… ${v.toStringAsFixed(0)}%';
            });
          case OtaStatus.INSTALLING:
            setState(() {
              _status = 'Installing…';
              _done = true;
            });
            Future<void>.delayed(const Duration(milliseconds: 800), () {
              if (mounted) Navigator.of(context).pop();
            });
          case OtaStatus.INSTALLATION_DONE:
            if (mounted) Navigator.of(context).pop();
          case OtaStatus.DOWNLOAD_ERROR:
          case OtaStatus.CHECKSUM_ERROR:
          case OtaStatus.INTERNAL_ERROR:
          case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
          case OtaStatus.ALREADY_RUNNING_ERROR:
          case OtaStatus.INSTALLATION_ERROR:
          case OtaStatus.CANCELED:
            setState(
              () => _status = 'Update failed: ${event.value ?? event.status}',
            );
            Future<void>.delayed(const Duration(seconds: 2), () {
              if (mounted) Navigator.of(context).pop();
            });
        }
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() => _status = 'Update failed');
        Future<void>.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.of(context).pop();
        });
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: const Text('Updating NEk0', style: TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _status,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 12),
          if (!_done)
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress / 100 : null,
                backgroundColor: Colors.grey[800],
                color: Colors.blue,
                minHeight: 6,
              ),
            ),
        ],
      ),
    );
  }
}
