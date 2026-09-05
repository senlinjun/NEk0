import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/foreground_service.dart';
import '../services/ft_service.dart';
import '../widgets/transfer_bar.dart';

/// Browse / upload / download a channel's TeamSpeak file storage.
class FileManagerScreen extends StatefulWidget {
  final int channelId;
  final String channelName;
  final String channelPassword;

  /// Whether the connection is alive right now (refreshes are no-ops when
  /// disconnected and a hint is shown instead of the list).
  final bool connected;

  const FileManagerScreen({
    super.key,
    required this.channelId,
    required this.channelName,
    this.channelPassword = '',
    required this.connected,
  });

  @override
  State<FileManagerScreen> createState() => _FileManagerScreenState();
}

class _FileManagerScreenState extends State<FileManagerScreen> {
  String _currentPath = '/';
  List<FtEntry> _entries = [];
  bool _loading = true;

  // Search mode state.
  bool _searchMode = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<_SearchHit> _searchHits = [];
  bool _searching = false;

  /// Set while any one-shot operation (delete/mkdir/single transfers) is
  /// running so toolbar buttons cannot be double-triggered.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // ─── Path helpers ─────────────────────────────────────────────────

  List<String> get _pathSegments =>
      _currentPath.split('/').where((s) => s.isNotEmpty).toList();

  String _join(String base, String name) {
    // A bare root joins without doubling the slash ("//name" never reaches
    // the server — some file-area commands reject it as an unknown path).
    return base == '/' || base.isEmpty ? '/$name' : '$base/$name';
  }

  String _parentOf(String p) {
    final segs = p.split('/').where((s) => s.isNotEmpty).toList()..removeLast();
    return segs.isEmpty ? '/' : '/${segs.join('/')}';
  }

  // ─── Data loading ─────────────────────────────────────────────────

  Future<void> _refresh() async {
    if (!widget.connected) return;
    setState(() {
      _loading = true;
    });
    try {
      final entries = await FtTransferService.instance
          .listDirectory(
            widget.channelId,
            _currentPath,
            password: widget.channelPassword,
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _entries = entries.where((e) => !e.isParent && e.name != '.').toList()
          ..sort(_entryCompare);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _fail(e);
    }
  }

  static int _entryCompare(FtEntry a, FtEntry b) {
    // Directories first, then case-insensitive by name.
    if (a.isFile != b.isFile) return a.isFile ? 1 : -1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  }

  void _navigate(String path) {
    setState(() {
      _currentPath = path;
      if (_searchMode) _exitSearch();
    });
    _refresh();
  }

  // ─── Toolbar actions ──────────────────────────────────────────────

  Future<void> _uploadOneFile() async {
    if (_busy) return;
    final al = AppLocalizations.of(context);
    try {
      final picked = await FilePicker.pickFile();
      if (!mounted || picked == null) return;
      final srcPath = picked.path;
      if (srcPath == null || !File(srcPath).existsSync()) return;
      setState(() => _busy = true);
      await FtTransferService.instance.uploadFile(
        widget.channelId,
        _join(_currentPath, picked.name),
        srcPath,
        password: widget.channelPassword,
      );
      if (!mounted) return;
      _toast(al.fmUploadDone);
    } catch (e) {
      if (!mounted) return;
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _uploadFolderRecursive() async {
    if (_busy) return;
    final al = AppLocalizations.of(context);
    try {
      final dirPath = await FilePicker.getDirectoryPath();
      if (!mounted || dirPath == null || dirPath.isEmpty) return;
      final dirName = dirPath.split('/').where((s) => s.isNotEmpty).lastOrNull;
      if (dirName == null || dirName.isEmpty) return;
      setState(() => _busy = true);
      await FtTransferService.instance.uploadFolder(
        widget.channelId,
        dirPath,
        _join(_currentPath, dirName),
        password: widget.channelPassword,
      );
      if (!mounted) return;
      _toast(al.fmUploadDone);
    } catch (e) {
      // Surface the server's real reason (permissions, invalid path, …).
      if (mounted) _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _createFolder() async {
    final al = AppLocalizations.of(context);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const _NewFolderDialog(),
    );
    if (!mounted || name == null || name.isEmpty) return;
    if (name.contains('/') ||
        name.contains('\\') ||
        name == '.' ||
        name == '..') {
      _toast(al.fmInvalidName);
      return;
    }
    setState(() => _busy = true);
    try {
      await FtTransferService.instance.mkDir(
        widget.channelId,
        _join(_currentPath, name),
        password: widget.channelPassword,
      );
      if (!mounted) return;
      _toast(al.fmFolderCreated);
    } catch (e) {
      if (!mounted) return;
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  // ─── Transfers & deletion ─────────────────────────────────────────

  Future<void> _downloadEntry(FtEntry entry) async {
    if (_busy) return;
    final al = AppLocalizations.of(context);
    setState(() => _busy = true);
    var ok = false;
    var message = '';
    try {
      final tmpDir = (await getTemporaryDirectory()).path;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      if (entry.isFile) {
        final remote = _join(_currentPath, entry.name);
        final target = '$tmpDir/nek0_$stamp/${entry.name}';
        await FtTransferService.instance.downloadFile(
          widget.channelId,
          remote,
          target,
          password: widget.channelPassword,
        );
        final dest = await ForegroundService.saveToDownloads(
          srcPath: target,
          displayName: entry.name,
          relativeDir: 'NEk0',
        );
        ok = dest != null && dest.isNotEmpty;
        message = ok ? dest : '';
      } else {
        final stageDir = '$tmpDir/nek0_$stamp';
        final count = await FtTransferService.instance.downloadFolder(
          widget.channelId,
          _join(_currentPath, entry.name),
          stageDir,
          password: widget.channelPassword,
        );
        // Hand each downloaded file to the shared Downloads collection;
        // only a successful export counts as overall success.
        var exported = 0;
        if (count > 0) {
          exported = await _exportStageToDownloads(stageDir, entry.name);
        }
        ok = exported > 0;
        message = ok ? '$exported' : '';
      }
      if (!mounted) return;
      if (ok) {
        _toast(
          message.isEmpty
              ? al.fmSavedToDownloads
              : '${al.fmSavedToDownloads}: $message',
        );
      } else {
        _toast(al.fmOperationFailed);
      }
    } catch (e) {
      // Surface the server's real reason instead of a generic failure.
      if (mounted) _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Copies everything staged under [stageDir] into the system Downloads
  /// collection under "Download/NEk0/<folder>/...". Returns the number of
  /// successfully exported files.
  Future<int> _exportStageToDownloads(
    String stageDir,
    String folderName,
  ) async {
    var count = 0;
    final root = Directory(stageDir);
    if (!await root.exists()) return 0;
    final files = <File>[];
    final dirs = <Directory>[root];
    while (dirs.isNotEmpty) {
      final d = dirs.removeAt(0);
      await for (final entity in d.list(followLinks: false)) {
        if (entity is File) {
          files.add(entity);
        } else if (entity is Directory) {
          dirs.add(entity);
        }
      }
    }
    for (final f in files) {
      final rel = f.path.startsWith('$stageDir/')
          ? f.path.substring(stageDir.length + 1)
          : f.uri.pathSegments.last;
      final segments = rel.split('/');
      segments.removeLast();
      final relDir = segments.isEmpty
          ? 'NEk0/$folderName'
          : 'NEk0/$folderName/${segments.join('/')}';
      final dest = await ForegroundService.saveToDownloads(
        srcPath: f.path,
        displayName: f.uri.pathSegments.last,
        relativeDir: relDir,
      );
      if (dest != null && dest.isNotEmpty) count += 1;
    }
    return count;
  }

  Future<void> _deleteEntry(FtEntry entry) async {
    final al = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(
          al.fmDelete,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          entry.isFile
              ? al.fmConfirmDeleteFile(entry.name)
              : al.fmConfirmDeleteFolder(entry.name),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              al.delete,
              style: const TextStyle(color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      final path = _join(_currentPath, entry.name);
      if (entry.isFile) {
        await FtTransferService.instance.deletePaths(widget.channelId, [
          path,
        ], password: widget.channelPassword);
      } else {
        // The confirm dialog promises the whole folder goes away; remove
        // the tree client-side so the outcome never depends on whether the
        // server deletes non-empty directories.
        await FtTransferService.instance.deleteTree(
          widget.channelId,
          path,
          password: widget.channelPassword,
        );
      }
      if (!mounted) return;
      _toast(al.fmDeleted);
    } catch (e) {
      // Surface the server's real reason (permissions, unknown path, …)
      // instead of swallowing it behind a generic failure message.
      if (!mounted) return;
      _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
      _refresh();
    }
  }

  void _showEntryActions(FtEntry entry) {
    final al = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF12122A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (entry.isFile)
              ListTile(
                leading: const Icon(
                  Icons.download,
                  size: 22,
                  color: Colors.blueAccent,
                ),
                title: Text(
                  al.fmDownload,
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _downloadEntry(entry);
                },
              ),
            ListTile(
              leading: const Icon(
                Icons.delete_forever,
                size: 22,
                color: Colors.redAccent,
              ),
              title: Text(
                al.fmDelete,
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _deleteEntry(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ─── Search ───────────────────────────────────────────────────────

  void _enterSearch() {
    setState(() {
      _searchMode = true;
      _searchHits = [];
    });
  }

  void _exitSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchMode = false;
      _searchHits = [];
      _searching = false;
    });
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchHits = [];
        _searching = false;
      });
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _runSearch(query.trim().toLowerCase());
    });
  }

  Future<void> _runSearch(String needle) async {
    setState(() => _searching = true);
    // Search the subtree below the CURRENT directory; relativePath values
    // are relative to it.
    final hits = <_SearchHit>[];
    final dirsToScan = <String>[''];
    var scanned = 0;
    try {
      while (dirsToScan.isNotEmpty &&
          scanned < 64 &&
          hits.length < 100 &&
          _searchMode) {
        final rel = dirsToScan.removeAt(0);
        scanned += 1;
        List<FtEntry> entries;
        try {
          entries = await FtTransferService.instance.listDirectory(
            widget.channelId,
            rel.isEmpty ? _currentPath : _join(_currentPath, rel),
            password: widget.channelPassword,
          );
        } catch (_) {
          continue;
        }
        for (final e in entries) {
          if (!_searchMode) break;
          if (e.isParent || e.name == '.') continue;
          final childRel = rel.isEmpty ? e.name : '$rel/${e.name}';
          if (e.name.toLowerCase().contains(needle)) {
            hits.add(_SearchHit(entry: e, relativePath: childRel));
          }
          if (!e.isFile) dirsToScan.add(childRel);
        }
      }
    } finally {}
    if (!mounted) return;
    setState(() {
      _searchHits = hits;
      _searching = false;
    });
  }

  // ─── Small UI pieces ──────────────────────────────────────────────

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// Single funnel for every operation failure so the server's raw reason
  /// reaches the user ("operation failed: <reason>"); known permission
  /// rejections get a friendly localized phrase, cancellations their own.
  void _fail(Object? error) {
    final al = AppLocalizations.of(context);
    if (error is TransferException && error.canceled) {
      _toast(al.fmCanceled);
      return;
    }
    final reason = error?.toString() ?? '';
    if (_permissionReasons.any(
      (needle) => reason.toLowerCase().contains(needle),
    )) {
      _toast(al.fmPermDenied);
      return;
    }
    _toast(al.fmReasonPrefix(reason.isEmpty ? '' : reason));
  }

  /// Fragments of TS3 permission-error identifiers (the Rust side formats
  /// them via the enum's Debug name plus a hex code).
  static const _permissionReasons = [
    'insufficientpermission',
    'permissioninvalid',
    'not enough permission',
    '0x0908',
  ];

  String _formatSize(int bytes) {
    if (bytes <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB'];
    double v = bytes.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u += 1;
    }
    return '${v.toStringAsFixed(v >= 10 || u == 0 ? 0 : 1)} ${units[u]}';
  }

  IconData _iconFor(FtEntry e) {
    if (!e.isFile) return Icons.folder;
    final n = e.name.toLowerCase();
    if (n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (n.endsWith('.mp3') ||
        n.endsWith('.wav') ||
        n.endsWith('.flac') ||
        n.endsWith('.ogg')) {
      return Icons.music_note_outlined;
    }
    if (n.endsWith('.mp4') || n.endsWith('.mkv') || n.endsWith('.avi')) {
      return Icons.movie_outlined;
    }
    if (n.endsWith('.zip') ||
        n.endsWith('.rar') ||
        n.endsWith('.7z') ||
        n.endsWith('.tar.gz')) {
      return Icons.folder_zip_outlined;
    }
    if (n.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (n.endsWith('.txt') || n.endsWith('.md') || n.endsWith('.log')) {
      return Icons.description_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final connected = widget.connected;

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F23),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.channelName,
              style: const TextStyle(fontSize: 15, color: Colors.white),
            ),
            Text(
              _searchMode ? al.fmSearch : '/${_pathSegments.join('/')}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildToolbar(connected),
            if (_searchMode) _buildSearchField(),
            Expanded(child: _buildBody(al, connected)),
            TransferBar(onClearFinished: () {}),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(bool connected) {
    final al = AppLocalizations.of(context);
    // Breadcrumb chips: root + each segment.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        color: const Color(0xFF16213E),
        height: 48,
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: al.fmUp,
              icon: Icon(
                Icons.arrow_upward,
                size: 20,
                color: _currentPath == '/'
                    ? Colors.grey.shade700
                    : Colors.white70,
              ),
              onPressed: (_currentPath == '/' || _busy)
                  ? null
                  : () => _navigate(_parentOf(_currentPath)),
            ),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _crumb('/', al.fmRootShort),
                  for (var i = 0; i < _pathSegments.length; i++)
                    _crumb(
                      '/${_pathSegments.take(i + 1).join('/')}',
                      _pathSegments[i],
                    ),
                ],
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: al.fmSearch,
              icon: const Icon(
                Icons.search,
                size: 20,
                color: Colors.blueAccent,
              ),
              onPressed: connected && !_busy
                  ? (_searchMode ? _exitSearch : _enterSearch)
                  : null,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: al.fmUploadFile,
              icon: const Icon(
                Icons.file_upload_outlined,
                size: 20,
                color: Colors.blueAccent,
              ),
              onPressed: connected && !_busy ? _uploadOneFile : null,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: al.fmUploadFolder,
              icon: const Icon(
                Icons.drive_folder_upload_outlined,
                size: 20,
                color: Colors.blueAccent,
              ),
              onPressed: connected && !_busy ? _uploadFolderRecursive : null,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: al.fmNewFolder,
              icon: const Icon(
                Icons.create_new_folder_outlined,
                size: 20,
                color: Colors.blueAccent,
              ),
              onPressed: connected && !_busy ? _createFolder : null,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: al.fmRefresh,
              // Spin while the listing is in flight; disabled while another
              // operation runs so requests don't stack.
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.blueAccent,
                      ),
                    )
                  : const Icon(
                      Icons.refresh,
                      size: 20,
                      color: Colors.blueAccent,
                    ),
              onPressed: connected && !_busy && !_loading ? _refresh : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _crumb(String path, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextButton.icon(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: Size.zero,
          foregroundColor: Colors.blueAccent,
        ),
        onPressed: path == _currentPath ? null : () => _navigate(path),
        icon: label == '/'
            ? const Icon(Icons.home_outlined, size: 14)
            : const SizedBox.shrink(),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Widget _buildBody(AppLocalizations al, bool connected) {
    if (!connected) {
      return Center(
        child: Text(
          al.fmNotConnected,
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Colors.blue));
    }
    if (_searchMode) {
      return _buildSearchResults(al);
    }
    if (_entries.isEmpty) {
      // Pull-to-refresh also works on the empty state, so a folder that
      // failed to load or really is empty can always be re-fetched.
      return RefreshIndicator(
        color: Colors.blue,
        backgroundColor: const Color(0xFF1A1A2E),
        onRefresh: _refresh,
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(
              height: constraints.maxHeight,
              child: Center(
                child: Text(
                  al.fmEmpty,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: Colors.blue,
      backgroundColor: const Color(0xFF1A1A2E),
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _entries.length,
        itemBuilder: (context, index) {
          final entry = _entries[index];
          return GestureDetector(
            // Desktop right-click: the same actions sheet as a long press.
            onSecondaryTapUp: (_) => _showEntryActions(entry),
            child: ListTile(
              dense: true,
              leading: Icon(
                _iconFor(entry),
                size: 20,
                color: entry.isFile ? Colors.blueGrey : Colors.amber.shade300,
              ),
              title: Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: entry.isFile
                  ? Text(
                      '${_formatSize(entry.size)}   '
                              '${DateTime.fromMillisecondsSinceEpoch(entry.datetime * 1000)}'
                          .trim(),
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                    )
                  : null,
              trailing: const SizedBox(width: 0),
              onTap: () {
                if (entry.isFile) {
                  _showEntryActions(entry);
                } else {
                  _navigate(_join(_currentPath, entry.name));
                }
              },
              onLongPress: () => _showEntryActions(entry),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchField() {
    final al = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: const Color(0xFF16213E),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                hintText: al.fmSearchHint,
                hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                border: InputBorder.none,
                icon: const Icon(Icons.search, color: Colors.grey, size: 18),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 18, color: Colors.grey),
            onPressed: _exitSearch,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(AppLocalizations al) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator(color: Colors.blue));
    }
    if (_searchHits.isEmpty) {
      return Center(
        child: Text(
          al.fmNoResults,
          style: const TextStyle(color: Colors.grey, fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      itemCount: _searchHits.length,
      itemBuilder: (context, index) {
        final hit = _searchHits[index];
        return ListTile(
          dense: true,
          leading: Icon(
            _iconFor(hit.entry),
            size: 20,
            color: hit.entry.isFile ? Colors.blueGrey : Colors.amber.shade300,
          ),
          title: Text(
            hit.entry.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          subtitle: Text(
            hit.relativePath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.grey, fontSize: 11),
          ),
          onTap: () {
            if (hit.entry.isFile) {
              // Download straight from search results.
              _downloadHit(hit);
            } else {
              _navigate(_join(_currentPath, hit.relativePath));
            }
          },
        );
      },
    );
  }

  Future<void> _downloadHit(_SearchHit hit) async {
    if (_busy) return;
    final al = AppLocalizations.of(context);
    setState(() => _busy = true);
    try {
      final tmpDir = (await getTemporaryDirectory()).path;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final target = '$tmpDir/nek0_s$stamp/${hit.entry.name}';
      await FtTransferService.instance.downloadFile(
        widget.channelId,
        '/${hit.relativePath}',
        target,
        password: widget.channelPassword,
      );
      final dest = await ForegroundService.saveToDownloads(
        srcPath: target,
        displayName: hit.entry.name,
        relativeDir: 'NEk0',
      );
      if (!mounted) return;
      _toast(
        dest != null && dest.isNotEmpty
            ? al.fmSavedToDownloads
            : al.fmOperationFailed,
      );
    } catch (e) {
      if (mounted) _fail(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _SearchHit {
  final FtEntry entry;
  final String relativePath;
  const _SearchHit({required this.entry, required this.relativePath});
}

/// New-folder name prompt. Owns its [TextEditingController] so it outlives the
/// dialog's exit transition ([State.dispose] runs only after the route's widget
/// tree has stopped rebuilding), preventing "used after being disposed"
/// crashes during the animated close frames. Pops the trimmed folder name, or
/// null when dismissed.
class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();

  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A2E),
      title: Text(
        al.fmNewFolder,
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: al.fmNewFolderName,
          hintStyle: const TextStyle(color: Colors.grey),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(al.cancel, style: const TextStyle(color: Colors.grey)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(
            al.send,
            style: const TextStyle(color: Colors.blueAccent),
          ),
        ),
      ],
    );
  }
}
