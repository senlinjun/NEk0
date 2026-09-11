import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/app_locale.dart';
import '../models/ts_state.dart';
import '../models/window_settings.dart';
import '../services/ts_ffi.dart';

/// Desktop-only root companion: owns the persistent tray icon, the
/// window-close behavior (ask / hide to tray / quit) and the graceful exit
/// path. Renders [child] unchanged and does nothing on Android.
///
/// Exit order matters: the connection notifier is asked to leave the server
/// first, then `TsNative.isConnected()` is polled until the Rust disconnect
/// handshake completes (bounded), and only then the window is destroyed —
/// so the server sees a clean leave instead of a dropped TCP connection.
class DesktopWindowScope extends ConsumerStatefulWidget {
  const DesktopWindowScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<DesktopWindowScope> createState() => _DesktopWindowScopeState();
}

class _DesktopWindowScopeState extends ConsumerState<DesktopWindowScope>
    with WindowListener, TrayListener {
  static const _menuShow = 'show';
  static const _menuDisconnect = 'disconnect';
  static const _menuQuit = 'quit';

  /// Guards re-entrant close events while a quit is in progress (the Linux
  /// window_manager plugin re-emits its close event during destroy()).
  bool _quitting = false;

  /// True while the close-ask dialog is on screen, so a second close event
  /// (double click on X) cannot stack another one.
  bool _dialogOpen = false;

  /// False when the tray icon could not be created — "hide to tray" then
  /// falls back to quitting, otherwise the window would be unreachable
  /// until the next app launch.
  bool _trayAvailable = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) return;
    windowManager.addListener(this);
    trayManager.addListener(this);
    // Post-frame: the tray menu needs AppLocalizations, which must not be
    // looked up before the first build (Localizations is not ready during
    // initState).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initTray();
    });
  }

  @override
  void dispose() {
    if (!Platform.isAndroid) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watching (not reading) keeps the settings notifier alive from startup
    // so the persisted close action is loaded long before the first close
    // click — ref.read in onWindowClose alone would construct the provider
    // lazily and still see the default for that first event.
    ref.watch(windowSettingsProvider);
    ref.listen(localeProvider, (_, __) {
      // Keep the tray menu labels in sync with the app language.
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateTrayMenu());
    });
    return widget.child;
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
      );
      // The Linux plugin only implements setIcon/setContextMenu; the DE
      // derives the tooltip itself there.
      if (Platform.isWindows) {
        await trayManager.setToolTip('NEk0');
      }
      await _updateTrayMenu();
      _trayAvailable = true;
    } catch (e) {
      // Tray unsupported (e.g. desktop shell without an AppIndicator host).
      debugPrint('tray icon unavailable: $e');
    }
  }

  Future<void> _updateTrayMenu() async {
    try {
      final l10n = AppLocalizations.of(context);
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: _menuShow, label: l10n.trayMenuShow),
            MenuItem(key: _menuDisconnect, label: l10n.trayMenuDisconnect),
            MenuItem.separator(),
            MenuItem(key: _menuQuit, label: l10n.trayMenuQuit),
          ],
        ),
      );
    } catch (e) {
      debugPrint('tray menu unavailable: $e');
    }
  }

  // ── WindowListener ────────────────────────────────────────────────

  @override
  void onWindowClose() {
    if (_quitting) return;
    switch (ref.read(windowSettingsProvider).closeAction) {
      case WindowCloseAction.ask:
        _showCloseDialog();
      case WindowCloseAction.hide when _trayAvailable:
        windowManager.hide();
      case WindowCloseAction.hide:
      case WindowCloseAction.exit:
        // Hiding without a tray would lose the window, so fall back to the
        // old behavior: quit.
        _performExit();
    }
  }

  // ── TrayListener ──────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Linux (appindicator) pops the menu natively and does not implement
    // this method; Windows needs the explicit popup.
    if (Platform.isWindows) trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuShow:
        _showWindow();
      case _menuDisconnect:
        ref.read(tsConnectionProvider.notifier).disconnect();
      case _menuQuit:
        _performExit();
    }
  }

  // ── Behavior ──────────────────────────────────────────────────────

  Future<void> _showWindow() async {
    if (await windowManager.isVisible()) {
      await windowManager.focus();
    } else {
      await windowManager.show();
    }
  }

  Future<void> _showCloseDialog() async {
    // A second close event while the dialog is up (double click on X) must
    // not stack another dialog on top.
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      final l10n = AppLocalizations.of(context);
      final connection = ref.read(tsConnectionProvider);
      final active = connection.connected || connection.connecting;
      var dontAskAgain = false;
      final action = await showDialog<WindowCloseAction>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(l10n.closeDialogTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  active ? l10n.closeDialogConnectedBody : l10n.closeDialogBody,
                ),
                CheckboxListTile(
                  value: dontAskAgain,
                  onChanged: (value) =>
                      setDialogState(() => dontAskAgain = value ?? false),
                  title: Text(l10n.closeDialogDontAskAgain),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(WindowCloseAction.hide),
                child: Text(l10n.closeDialogHide),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(WindowCloseAction.exit),
                child: Text(l10n.closeDialogQuit),
              ),
            ],
          ),
        ),
      );
      if (action == null) return;
      if (dontAskAgain) {
        await ref.read(windowSettingsProvider.notifier).setCloseAction(action);
      }
      if (action == WindowCloseAction.hide && _trayAvailable) {
        await windowManager.hide();
      } else {
        await _performExit();
      }
    } finally {
      _dialogOpen = false;
    }
  }

  /// Leaves the server (if connected), waits for the Rust disconnect
  /// handshake to finish, then tears down the window. Bounded so a dead
  /// network link cannot hang the exit forever; the server cleans up such
  /// ghosts on its own after a timeout.
  Future<void> _performExit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      final connection = ref.read(tsConnectionProvider);
      if (connection.connected || connection.connecting) {
        await ref.read(tsConnectionProvider.notifier).disconnect();
      }
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (TsNative.isConnected() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (e) {
      debugPrint('exit cleanup failed (quitting anyway): $e');
    }
    try {
      // destroy() clears the prevent-close flag internally on Linux;
      // unsetting it here too keeps both platforms explicit about letting
      // the window die.
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (e) {
      debugPrint('window destroy failed: $e');
    }
    // Last-resort fallback in case the window manager could not quit the
    // app; all cleanup above is already done at this point.
    exit(0);
  }
}
