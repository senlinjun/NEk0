import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_locale.dart';
import '../models/channel.dart';
import '../models/client.dart';
import '../models/chat_message.dart';
import '../models/perm.dart';
import '../models/server.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/ts_ffi.dart';
import '../services/audio_service.dart';
import '../services/avatar_cache.dart';
import '../services/foreground_service.dart';
import '../services/ft_service.dart';

// ─── Immutable State ────────────────────────────────────────────────

class TsConnectionState {
  final bool connected;
  final bool connecting;
  final String serverName;
  final String nickname;
  final int ownClientId;
  final List<TsChannel> channels;
  final List<TsClient> clients;
  final List<ChatMessage> messages;
  final int? selectedChannelId;

  /// Channel id whose join was just rejected because of a wrong password.
  /// Transient marker consumed by the server screen to re-open the prompt.
  final int? failedPasswordChannelId;

  /// The server announced `ask_for_privilegekey` and no token was submitted
  /// with clientinit — the server screen should offer the privilege-key
  /// dialog. Reset once handled or on disconnect.
  final bool askForPrivilegeKey;
  final String? error;
  final List<String> diagMessages;
  final bool voiceActive;
  final bool inputMuted;
  final bool outputMuted;
  final bool away;
  final bool pttMode;
  final bool pttPressed;
  final bool vadEnabled;
  final double vadThreshold;
  final double micGain;
  final double micRms;

  const TsConnectionState({
    this.connected = false,
    this.connecting = false,
    this.serverName = '',
    this.nickname = '',
    this.ownClientId = 0,
    this.channels = const [],
    this.clients = const [],
    this.messages = const [],
    this.selectedChannelId,
    this.failedPasswordChannelId,
    this.askForPrivilegeKey = false,
    this.error,
    this.diagMessages = const [],
    this.voiceActive = false,
    this.inputMuted = false,
    this.outputMuted = false,
    this.away = false,
    this.pttMode = false,
    this.pttPressed = false,
    this.vadEnabled = true,
    this.vadThreshold = 0.005,
    this.micGain = 1.0,
    this.micRms = 0.0,
  });

  TsConnectionState copyWith({
    bool? connected,
    bool? connecting,
    String? serverName,
    String? nickname,
    int? ownClientId,
    List<TsChannel>? channels,
    List<TsClient>? clients,
    List<ChatMessage>? messages,
    Object? selectedChannelId = _sentinel,
    Object? failedPasswordChannelId = _sentinel,
    bool? askForPrivilegeKey,
    String? error,
    List<String>? diagMessages,
    bool? voiceActive,
    bool? inputMuted,
    bool? outputMuted,
    bool? away,
    bool? pttMode,
    bool? pttPressed,
    bool? vadEnabled,
    double? vadThreshold,
    double? micGain,
    double? micRms,
  }) => TsConnectionState(
    connected: connected ?? this.connected,
    connecting: connecting ?? this.connecting,
    serverName: serverName ?? this.serverName,
    nickname: nickname ?? this.nickname,
    ownClientId: ownClientId ?? this.ownClientId,
    channels: channels ?? this.channels,
    clients: clients ?? this.clients,
    messages: messages ?? this.messages,
    selectedChannelId: selectedChannelId == _sentinel
        ? this.selectedChannelId
        : selectedChannelId as int?,
    failedPasswordChannelId: failedPasswordChannelId == _sentinel
        ? this.failedPasswordChannelId
        : failedPasswordChannelId as int?,
    askForPrivilegeKey: askForPrivilegeKey ?? this.askForPrivilegeKey,
    error: error,
    diagMessages: diagMessages ?? this.diagMessages,
    voiceActive: voiceActive ?? this.voiceActive,
    inputMuted: inputMuted ?? this.inputMuted,
    outputMuted: outputMuted ?? this.outputMuted,
    away: away ?? this.away,
    pttMode: pttMode ?? this.pttMode,
    pttPressed: pttPressed ?? this.pttPressed,
    vadEnabled: vadEnabled ?? this.vadEnabled,
    vadThreshold: vadThreshold ?? this.vadThreshold,
    micGain: micGain ?? this.micGain,
    micRms: micRms ?? this.micRms,
  );
}

const _sentinel = Object();

// ─── Saved Servers State ────────────────────────────────────────────

class ServerListState {
  final List<Server> servers;
  final bool loading;

  const ServerListState({this.servers = const [], this.loading = true});

  ServerListState copyWith({List<Server>? servers, bool? loading}) =>
      ServerListState(
        servers: servers ?? this.servers,
        loading: loading ?? this.loading,
      );
}

// ─── Connection Notifier (calls real Rust FFI) ──────────────────────

class TsConnectionNotifier extends Notifier<TsConnectionState> {
  Timer? _pollTimer;
  AudioService? _audioService;
  bool _micEnabled = false;
  bool _micGranted =
      false; // true only after enableMic() successfully completes
  bool _inputMutedBeforeAway = false; // input mute to restore when leaving away
  SharedPreferences? _prefs; // cached for synchronous saves
  // UIDs whose saved 2D position has been applied this session (see
  // _applySavedClientPositions). Afterwards live Rust state is authoritative.
  final Set<String> _positionedUids = {};
  // Session-only cache of channel passwords entered by the user, keyed by
  // channel id. Cleared on disconnect; deliberately never persisted to disk.
  final Map<int, String> _channelPasswords = {};
  // Id of the server whose one-time privilege key (token) was submitted with
  // the current connect attempt; cleared from the server entry once the
  // connection succeeds.
  String? _pendingTokenServerId;
  // True when the current connect attempt carried a pre-filled token in
  // clientinit — suppresses the post-connect privilege-key prompt for that
  // connection (the server already got a key).
  bool _clientinitTokenSubmitted = false;

  /// Pending permission-management operations: token → completer. Resolved by
  /// the `perm_op` event handler; timed out after 8s by the caller.
  final Map<String, Completer<String?>> _permCompleters = {};
  int _permSeq = 0;

  /// OUR OWN directly-assigned permissions (from Rust `ts_get_own_perms`),
  /// refreshed after connect. Low-threshold hint for UI affordances only.
  List<TsPerm> _ownPerms = const [];

  /// True when our own directly-assigned permissions include any of the
  /// management powers (client perm modify / group member add / channel perm
  /// modify with a positive value). Used to show the permission-management
  /// entry even when the server pushes no permission hints. Note:
  /// `clientpermlist` only lists DIRECTLY-assigned perms, so a server admin
  /// whose powers come from groups will not be detected here — that is the
  /// known low-threshold limitation (their hints usually arrive anyway).
  bool get canManagePermissions => _ownPerms.any((p) {
    if (!p.effectivePositive) return false;
    return p.name == PermNames.clientPermissionModify ||
        p.name == PermNames.groupMemberAdd ||
        p.name == PermNames.channelPermissionModify;
  });

  /// Localized strings without a BuildContext (same pattern as the
  /// notification labels).
  AppLocalizations? get _l10n =>
      ref.read(localeProvider.notifier).localizations;

  @override
  TsConnectionState build() {
    ForegroundService.init();
    ForegroundService.onToggleMute = (bool inputMuted) {
      if (state.inputMuted != inputMuted) {
        toggleInputMute();
      }
    };
    ForegroundService.onSetAwayMute = setAwayAndFullMute;
    ForegroundService.onNotificationDisconnect = () {
      disconnect();
    };

    ref.onDispose(() {
      _pollTimer?.cancel();
      ForegroundService.onToggleMute = null;
      ForegroundService.onSetAwayMute = null;
      ForegroundService.onNotificationDisconnect = null;
    });
    return const TsConnectionState();
  }

  Future<void> _saveIdentity() async {
    final id = TsNative.getIdentity();
    if (id != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('client_identity', id);
      debugPrint('TS: identity saved to storage');
    }
  }

  Future<void> connect({
    required String address,
    required String nickname,
    String? channel,
    String? password,
    String? token,
    String? serverId,
  }) async {
    debugPrint(
      'TS: connect($address, $nickname, ch=$channel, token=${token != null})',
    );
    state = state.copyWith(connecting: true, error: null);
    _pendingTokenServerId = token != null ? serverId : null;
    _clientinitTokenSubmitted = token != null;

    // Push persisted identity to Rust before connecting
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs; // cache for synchronous saves
    _migrateLegacyVolumeKeys();
    final id = prefs.getString('client_identity');
    if (id != null) {
      debugPrint('TS: pushing identity to Rust');
      TsNative.setIdentity(id);
    }
    final savedMicGain = prefs.getDouble('mic_gain');
    if (savedMicGain != null) {
      TsNative.setMicGain(savedMicGain);
      state = state.copyWith(micGain: savedMicGain);
    }
    // Apply persisted audio device choices before any stream is built
    // (desktop only — Android routes through the system automatically).
    if (!Platform.isAndroid) {
      TsNative.setAudioOutputDevice(
        prefs.getString('audio_output_device') ?? '',
      );
      TsNative.setAudioInputDevice(prefs.getString('audio_input_device') ?? '');
    }

    // Call Rust FFI - starts async connection in background
    final resultJson = TsNative.connect(
      address,
      nickname,
      channel: channel,
      password: password,
      token: token,
    );
    debugPrint('TS: connect result = $resultJson');
    final result = jsonDecode(resultJson) as Map<String, dynamic>;

    if (result['type'] == 'error') {
      state = state.copyWith(
        connecting: false,
        error: result['message'] as String,
      );
      return;
    }

    // Start polling for events from Rust
    _startPolling();
  }

  void _startPolling() {
    debugPrint('TS: polling started');
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _pollEvents();
    });
  }

  void _pollEvents() {
    try {
      final eventsJson = TsNative.pollEvents();
      final events = jsonDecode(eventsJson) as List;
      if (events.isNotEmpty) debugPrint('TS: poll got ${events.length} events');

      for (final raw in events) {
        final event = raw as Map<String, dynamic>;
        // Catch per event: the batch is already drained from Rust, so a
        // batch-level failure would silently drop every later event — e.g.
        // the perm_op receipt a dialog is awaiting.
        try {
          _handleEvent(event);
        } catch (e) {
          debugPrint('TS: event ${event['type']} handler error: $e');
        }
      }
      // Poll voice activity for UI indicator
      final va = TsNative.isVoiceActive();
      if (va != state.voiceActive) {
        state = state.copyWith(voiceActive: va);
        _refreshNotification();
      }
      // Refresh client talking indicators from live Rust data
      try {
        final clientsJson = TsNative.getClients();
        final clients = (jsonDecode(clientsJson) as List)
            .map((j) => TsClient.fromJson(j as Map<String, dynamic>))
            .toList();
        if (clients.isNotEmpty) {
          state = state.copyWith(clients: clients);
        }
      } catch (_) {} // ignore parse errors during refresh
      // Queue downloads for newly seen client avatars (no-op when all
      // hashes are already cached/queued/failed).
      ref.read(avatarCacheProvider.notifier).updateFromClients(state.clients);
      // Apply saved per-client volumes (UID-keyed) to any client whose volume
      // differs from the saved value. Runs on every refresh, so it also covers
      // late joiners and the brief window where a UID is not yet known.
      _applySavedClientVolumes();
      _applySavedClientPositions();
    } catch (e) {
      debugPrint('FFI poll error: $e');
    }
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['type'] as String;
    debugPrint('TS: event $type');
    switch (type) {
      case 'connected':
        // Connection succeeded - refresh channels/clients from Rust
        final channelsJson = TsNative.getChannels();
        final clientsJson = TsNative.getClients();

        final channels = (jsonDecode(channelsJson) as List)
            .map((j) => TsChannel.fromJson(j as Map<String, dynamic>))
            .toList();
        final clients = (jsonDecode(clientsJson) as List)
            .map((j) => TsClient.fromJson(j as Map<String, dynamic>))
            .toList();

        final ownId = event['client_id'] as int? ?? state.ownClientId;
        // Find the channel the user is actually in
        final ownClient = clients.where((c) => c.id == ownId).firstOrNull;
        final joinedChannelId = ownClient?.channelId;

        state = state.copyWith(
          connecting: false,
          connected: true,
          serverName: event['server_name'] as String? ?? state.serverName,
          ownClientId: ownId,
          channels: channels,
          clients: clients,
          selectedChannelId: joinedChannelId,
          // Offer the privilege-key dialog only when the server asks AND we
          // did not already hand it a key in clientinit.
          askForPrivilegeKey:
              (event['ask_for_privilegekey'] as bool? ?? false) &&
              !_clientinitTokenSubmitted,
        );

        // The privilege key was redeemed by the server during the handshake —
        // privilege keys are one-time, so drop it from the saved server.
        final tokenServerId = _pendingTokenServerId;
        _pendingTokenServerId = null;
        _clientinitTokenSubmitted = false;
        if (tokenServerId != null) {
          final servers = ref.read(serverListProvider).servers;
          final idx = servers.indexWhere((s) => s.id == tokenServerId);
          if (idx >= 0) {
            ref
                .read(serverListProvider.notifier)
                .updateServer(servers[idx].copyWith(clearToken: true));
          }
        }

        // Kick off avatar downloads right away (the poll loop would catch
        // them on its next tick anyway).
        ref.read(avatarCacheProvider.notifier).updateFromClients(clients);
        // Auto-start audio playback (listening is always on in Teamspeak)
        _audioService = AudioService();
        _audioService!.onMicLevel = (double rms) {
          state = state.copyWith(micRms: rms);
        };
        _audioService!.start();
        // Init VAD defaults and start mic via control flow
        TsNative.setVadEnabled(true);
        TsNative.setVadThreshold(state.vadThreshold);
        _updateMicState();
        ForegroundService.start(
          title: state.serverName,
          text: _currentChannelName,
          mic: false,
          inputMuted: state.inputMuted,
          fullMuted: state.inputMuted && state.outputMuted,
          muteLabel: _notifMuteLabel,
          unmuteLabel: _notifUnmuteLabel,
          disconnectLabel: _notifDisconnectLabel,
        );
        // Battery-optimization exemption is requested AFTER the first-connect
        // OEM guide dialog (server_screen._maybeShowOemGuide), so the user
        // knows why the system settings page opens.
        _saveIdentity();
        // Pull our own directly-assigned permissions (clientpermlist answer
        // is requested by the Rust side on connect; read it back now).
        refreshOwnPerms();
        break;

      case 'disconnected':
        if (state.connecting)
          break; // stale event from previous connection, ignore
        _pollTimer?.cancel();
        _audioService?.stop();
        _audioService = null;
        ForegroundService.stop();
        _channelPasswords.clear();
        ref.read(avatarCacheProvider.notifier).reset();
        for (final c in _permCompleters.values) {
          c.complete(_l10n?.permNotConnected ?? 'Not connected');
        }
        _permCompleters.clear();
        _ownPerms = const [];
        state = const TsConnectionState();
        break;

      case 'error':
        if (state.connecting) {
          state = state.copyWith(
            connecting: false,
            error: event['message'] as String,
          );
          _pollTimer?.cancel();
        }
        break;

      case 'text_message':
        final msg = ChatMessage(
          id: state.messages.length,
          fromClient: event['from_client'] as String,
          fromClientId: event['from_client_id'] as int,
          targetMode: event['target_mode'] as int,
          message: event['message'] as String,
          timestamp: DateTime.now(),
        );
        state = state.copyWith(messages: [...state.messages, msg]);
        break;

      case 'poke':
        // A poke is NOT a chat message — show a system notification.
        final from = event['from_client'] as String? ?? '';
        final pokeMsg = event['message'] as String? ?? '';
        final al = ref.read(localeProvider.notifier).localizations;
        ForegroundService.notifyPoke(
          title: al?.pokeNotificationTitle ?? 'You were poked',
          body:
              (al?.pokeNotificationBody(from, pokeMsg) ??
              '$from poked you: $pokeMsg'),
        );
        break;

      case 'client_joined':
        final client = TsClient(
          id: event['client_id'] as int,
          nickname: event['nickname'] as String,
          channelId: event['channel_id'] as int,
        );
        state = state.copyWith(clients: [...state.clients, client]);
        break;

      case 'client_left':
        final leftId = event['client_id'] as int;
        state = state.copyWith(
          clients: state.clients.where((c) => c.id != leftId).toList(),
        );
        break;

      case 'diag':
        final msg = event['msg'] as String;
        debugPrint('RUST: $msg');
        state = state.copyWith(diagMessages: [...state.diagMessages, msg]);
        break;

      case 'move_rejected':
        // Only emitted for invalid-channel-password rejections; roll back
        // the optimistic selection and prompt the user again via the UI.
        final rejectedCid = event['channel_id'] as int;
        _channelPasswords.remove(rejectedCid);
        final own = state.clients
            .where((c) => c.id == state.ownClientId)
            .firstOrNull;
        state = state.copyWith(
          selectedChannelId: own?.channelId,
          failedPasswordChannelId: rejectedCid,
        );
        break;

      case 'channels_updated':
        // Re-fetch channels and clients from Rust cache
        final chJson = TsNative.getChannels();
        final clJson = TsNative.getClients();
        final newChannels = (jsonDecode(chJson) as List)
            .map((j) => TsChannel.fromJson(j as Map<String, dynamic>))
            .toList();
        final newClients = (jsonDecode(clJson) as List)
            .map((j) => TsClient.fromJson(j as Map<String, dynamic>))
            .toList();
        state = state.copyWith(channels: newChannels, clients: newClients);
        _refreshNotification();
        break;

      // File-transfer events are routed to their own service so they never
      // touch the connection state object (no global rebuild churn).
      case 'ft_listing':
      case 'ft_started':
      case 'ft_progress':
      case 'ft_done':
      case 'ft_op':
        FtTransferService.instance.handleEvent(event);
        break;

      case 'perm_op':
        // Result of a permission-management command (group add/remove,
        // channel group set/clear, channel perm grant/revoke). Resolves the
        // awaiting completer: null = success, otherwise the server error.
        final token = event['token'] as String;
        final ok = event['ok'] as bool? ?? false;
        final error = event['error'] as String?;
        final completer = _permCompleters.remove(token);
        if (completer != null) {
          if (ok) {
            completer.complete(null);
          } else {
            completer.complete(
              error?.isNotEmpty == true
                  ? error
                  : (_l10n?.permFailedUnknown ??
                        'The server rejected the request'),
            );
          }
        }
        break;
    }
  }

  Future<void> disconnect() async {
    debugPrint('TS: disconnect called, connected=${state.connected}');
    if (!state.connected && !state.connecting) return;
    // Ask Rust first: ts_disconnect sets the pending-disconnect flag
    // synchronously, so ts_stop_audio below keeps the output stream alive
    // until the "disconnected" sound finishes playing.
    TsNative.disconnect(); // sends Command::Disconnect to event loop
    _audioService?.stop();
    _audioService = null;
    _micEnabled = false;
    ForegroundService.stop();
    // Let the real 'disconnected' event from the event loop drive cleanup.
    // The poll timer keeps running — _handleEvent('disconnected') will
    // cancel it, reset state, and trigger the server_screen pop listener.
    state = state.copyWith(connecting: false);
  }

  Future<void> sendChannelMessage(String text) async {
    if (!state.connected || text.isEmpty) return;
    debugPrint(
      'TS: sendChannelMessage(cid=${state.selectedChannelId}, len=${text.length})',
    );
    TsNative.sendChannelMessage(state.selectedChannelId ?? 0, text);
    // Don't add optimistically — server echoes back as a text_message event
  }

  Future<void> sendPrivateMessage(int clientId, String text) async {
    if (!state.connected || text.isEmpty) return;
    final msg = ChatMessage(
      id: state.messages.length,
      fromClient: state.nickname,
      fromClientId: state.ownClientId,
      targetMode: 1,
      message: text,
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, msg]);
  }

  /// The password entered for a locked channel during this session
  /// (null when none was entered yet).
  String? channelPassword(int channelId) => _channelPasswords[channelId];

  /// Clears the transient "password rejected" marker (after the retry
  /// prompt has been shown, whether or not the user retries).
  void clearPasswordRejection() {
    if (state.failedPasswordChannelId != null) {
      state = state.copyWith(failedPasswordChannelId: null);
    }
  }

  void selectChannel(int channelId, {String? password}) {
    debugPrint('TS: selectChannel($channelId)');
    if (!state.connected) return;
    final channel = state.channels.where((c) => c.id == channelId).firstOrNull;
    var effectivePassword = password;
    if (channel?.hasPassword ?? false) {
      if (effectivePassword == null || effectivePassword.isEmpty) {
        effectivePassword = _channelPasswords[channelId];
      }
      if (effectivePassword == null || effectivePassword.isEmpty) return;
      _channelPasswords[channelId] = effectivePassword;
    }
    // Reset any previous rejection marker BEFORE sending, so a repeat
    // failure with the same channel id still re-triggers UI listeners.
    state = state.copyWith(
      failedPasswordChannelId: null,
      selectedChannelId: channelId,
    );
    TsNative.moveToChannel(channelId, password: effectivePassword);
  }

  // ─── Voice control flow ──────────────────────────────────────────

  String get _currentChannelName {
    final own = state.clients
        .where((c) => c.id == state.ownClientId)
        .firstOrNull;
    if (own == null) return '';
    return state.channels
            .where((c) => c.id == own.channelId)
            .firstOrNull
            ?.name ??
        '';
  }

  // ─── Localized notification labels (no BuildContext here — read the
  // cached AppLocalizations from the locale provider) ───────────────────

  String get _notifMuteLabel =>
      ref.read(localeProvider.notifier).localizations?.notifMute ?? 'Mute';

  String get _notifUnmuteLabel =>
      ref.read(localeProvider.notifier).localizations?.notifUnmute ?? 'Unmute';

  String get _notifDisconnectLabel =>
      ref.read(localeProvider.notifier).localizations?.notifDisconnect ??
      'Disconnect';

  void _refreshNotification({bool? mic}) {
    final hasMic = mic ?? _micGranted;
    var text = _currentChannelName;
    if (!state.inputMuted || state.voiceActive) {
      text = '$text \u2014 Speaking';
    }
    ForegroundService.update(
      title: state.serverName,
      text: text,
      mic: hasMic,
      inputMuted: state.inputMuted,
      fullMuted: state.inputMuted && state.outputMuted,
      muteLabel: _notifMuteLabel,
      unmuteLabel: _notifUnmuteLabel,
      disconnectLabel: _notifDisconnectLabel,
    );
  }

  /// Diagram: Start -> away? -> nothing : PTT? -> pushed? -> send : mute? -> send : nothing
  bool get _shouldMicBeActive {
    if (state.away) return false;
    if (state.pttMode) return state.pttPressed;
    return !state.inputMuted;
  }

  void _updateMicState() {
    if (_audioService == null) return;
    final should = _shouldMicBeActive;
    if (should && !_micEnabled) {
      _audioService!.enableMic().then((granted) {
        if (granted) {
          _micGranted = true;
          _refreshNotification(mic: true);
        }
      });
      _micEnabled = true;
    } else if (!should && _micEnabled) {
      _audioService!.disableMic();
      _micEnabled = false;
      _micGranted = false;
      _refreshNotification(mic: false);
    }
  }

  void togglePttMode() {
    final newPtt = !state.pttMode;
    state = state.copyWith(pttMode: newPtt);
    if (newPtt) {
      TsNative.setVadEnabled(false);
    } else {
      TsNative.setVadEnabled(state.vadEnabled);
      TsNative.setVadThreshold(state.vadThreshold);
    }
    _updateMicState();
  }

  void setPttPressed(bool pressed) {
    state = state.copyWith(pttPressed: pressed);
    _updateMicState();
  }

  void toggleInputMute() {
    final newMuted = !state.inputMuted;
    state = state.copyWith(inputMuted: newMuted);
    TsNative.setMuted(input: newMuted, output: state.outputMuted);
    _updateMicState();
    _refreshNotification();
  }

  /// Media card control: pause = away + full mute (sound off), play =
  /// away off + sound on. This replaces the removed headset full-mute toggle;
  /// it is invoked via the platform channel from the Android media card
  /// (KeepAliveService onPause/onPlay).
  void setAwayAndFullMute(bool away, bool muted) {
    _inputMutedBeforeAway = state.inputMuted;
    state = state.copyWith(away: away, inputMuted: muted, outputMuted: muted);
    TsNative.setAway(away);
    TsNative.setMuted(input: muted, output: muted);
    _updateMicState();
    _refreshNotification();
  }

  void toggleOutputMute() {
    final newMuted = !state.outputMuted;
    state = state.copyWith(outputMuted: newMuted);
    TsNative.setMuted(input: state.inputMuted, output: newMuted);
    _refreshNotification();
  }

  /// Toggle our own away state. Entering away auto-mutes the mic (input) and
  /// stops capture; leaving away restores the input-mute state from before.
  /// Output is not touched by the manual toggle. The server echo drives the
  /// away_activated/away_deactivated sounds via the Rust event loop.
  void toggleAway() {
    if (!state.connected) return;
    final newAway = !state.away;
    final newInputMuted = newAway ? true : _inputMutedBeforeAway;
    if (newAway) _inputMutedBeforeAway = state.inputMuted;
    state = state.copyWith(away: newAway, inputMuted: newInputMuted);
    TsNative.setAway(newAway);
    TsNative.setMuted(input: newInputMuted, output: state.outputMuted);
    _updateMicState();
    _refreshNotification();
  }

  /// Poke another client (sends a notifyclientpoke request).
  void sendPoke(int clientId, String message) {
    if (!state.connected) return;
    TsNative.sendPoke(clientId, message);
  }

  /// Kick a client from the current channel ([fromServer] == false) or the
  /// whole server ([fromServer] == true). Only call when the client's
  /// permission hints allow it; an empty [reason] kicks without a reason
  /// message (only the dialog's dismissal cancels, before reaching us).
  /// Returns null on success or a human-readable error description (server
  /// rejection, timeout, ...) — the server's real answer arrives through
  /// `perm_op`.
  Future<String?> kickClient(
    int clientId, {
    required bool fromServer,
    String reason = '',
  }) {
    return _permOp(
      (t) => TsNative.kickClient(
        clientId,
        fromServer: fromServer,
        reason: reason,
        token: t,
      ),
    );
  }

  /// Ban a client; [timeSeconds] == 0 is a permanent ban. Returns null on
  /// success or a human-readable error description.
  Future<String?> banClient(
    int clientId, {
    required int timeSeconds,
    String reason = '',
  }) {
    if (reason.isEmpty && timeSeconds == 0) {
      return Future.value(_l10n?.banCanceled ?? 'Ban canceled');
    }
    return _permOp(
      (t) => TsNative.banClient(
        clientId,
        timeSeconds: timeSeconds,
        reason: reason,
        token: t,
      ),
    );
  }

  /// Move a client (or ourselves) to another channel. Returns null on
  /// success or a human-readable error description.
  Future<String?> moveClient(int clientId, int channelId, {String? password}) =>
      _permOp(
        (t) => TsNative.moveClient(
          clientId,
          channelId,
          password: password,
          token: t,
        ),
      );

  // ─── Channel management ────────────────────────────────────────────

  /// Creates a channel under [parentId] (0 = top level). [maxFamilyClients]:
  /// -1 inherited, 0 unlimited, >0 limit. [deleteDelay] in seconds applies to
  /// temporary channels. Returns null on success or an error description.
  Future<String?> createChannel(
    int parentId,
    String name, {
    String? topic,
    String? password,
    String? description,
    int? maxClients,
    int? maxFamilyClients,
    required bool isPermanent,
    required bool isSemiPermanent,
    bool isDefault = false,
    int? deleteDelay,
  }) {
    return _permOp(
      (t) => TsNative.createChannel({
        'parent_id': parentId,
        'name': name,
        if (topic != null) 'topic': topic,
        if (password != null) 'password': password,
        if (description != null) 'description': description,
        if (maxClients != null) 'max_clients': maxClients,
        if (maxFamilyClients != null) 'max_family_clients': maxFamilyClients,
        'is_permanent': isPermanent,
        'is_semi_permanent': isSemiPermanent,
        'is_default': isDefault,
        if (deleteDelay != null) 'delete_delay': deleteDelay,
      }, token: t),
    );
  }

  /// Edits channel properties. Null fields are left untouched; an empty
  /// [password] clears it (null keeps it); [maxFamilyClients]: -1 inherited,
  /// 0 unlimited, >0 limit; [order] = the sibling id this channel comes
  /// after (0 = first); [neededTalkPower] >= 0 sets the talk gate. Returns
  /// null on success or an error description.
  Future<String?> editChannel(
    int channelId, {
    String? name,
    String? topic,
    String? password,
    String? description,
    int? maxClients,
    int? maxFamilyClients,
    bool? isPermanent,
    bool? isSemiPermanent,
    bool? isDefault,
    int? deleteDelay,
    int? neededTalkPower,
    int? order,
  }) {
    return _permOp(
      (t) => TsNative.editChannel(channelId, {
        if (name != null) 'name': name,
        if (topic != null) 'topic': topic,
        if (password != null) 'password': password,
        if (description != null) 'description': description,
        if (maxClients != null) 'max_clients': maxClients,
        if (maxFamilyClients != null) 'max_family_clients': maxFamilyClients,
        if (isPermanent != null) 'is_permanent': isPermanent,
        if (isSemiPermanent != null) 'is_semi_permanent': isSemiPermanent,
        if (isDefault != null) 'is_default': isDefault,
        if (deleteDelay != null) 'delete_delay': deleteDelay,
        if (neededTalkPower != null) 'needed_talk_power': neededTalkPower,
        if (order != null) 'order': order,
      }, token: t),
    );
  }

  /// Deletes a channel ([force] also removes one that still has clients —
  /// its occupants are moved to the default channel). Returns null on
  /// success or an error description.
  Future<String?> deleteChannel(int channelId, {required bool force}) =>
      _permOp((t) => TsNative.deleteChannel(channelId, force: force, token: t));

  /// Moves a channel to another parent (0 = server root) and optionally
  /// positions it after [afterId] within the new parent (0 = first; null =
  /// appended at the end). Also re-orders within the same parent. Returns
  /// null on success or an error description.
  Future<String?> moveChannel(
    int channelId, {
    required int parentId,
    int? afterId,
  }) {
    return _permOp(
      (t) => TsNative.moveChannelTo(
        channelId,
        parentId: parentId,
        order: afterId,
        token: t,
      ),
    );
  }

  // ─── Permission management ─────────────────────────────────────────

  /// Re-reads our own directly-assigned permissions from the Rust cache
  /// (filled by the `clientpermlist` answer requested on connect).
  void refreshOwnPerms() {
    try {
      _ownPerms = TsNative.getOwnPerms().map(TsPerm.fromJson).toList();
    } catch (_) {
      _ownPerms = const [];
    }
  }

  /// Redeems a privilege key (admin token) on the connected server via
  /// `clientupdate client_default_token`. Returns null when the server
  /// accepted the command, or an error description. Note: a server may
  /// accept the command yet silently ignore an invalid/used key — the
  /// caller should confirm the effect via the client's server groups.
  Future<String?> usePrivilegeKey(String token) =>
      _permOp((t) => TsNative.usePrivilegeKey(token, t));

  /// Marks the connection's privilege-key prompt as handled (dismissed or
  /// submitted) so it is not offered again until the next connect.
  void clearAskForPrivilegeKey() {
    if (state.askForPrivilegeKey) {
      state = state.copyWith(askForPrivilegeKey: false);
    }
  }

  /// Runs a permission-management command and awaits the server's answer.
  /// Returns null on success, or a human-readable error description.
  Future<String?> _permOp(bool Function(String token) send) async {
    if (!state.connected) {
      debugPrint('TS: perm op rejected: not connected');
      return _l10n?.permNotConnected ?? 'Not connected';
    }
    final token = 'perm_${_permSeq++}';
    final completer = Completer<String?>();
    _permCompleters[token] = completer;
    // The FFI call itself can throw (e.g. a stale native library that lacks
    // the symbol — hot reload does not refresh the .so). Catch it so the tap
    // surfaces an error instead of dying as an uncaught exception with no
    // reaction at all.
    bool queued;
    try {
      queued = send(token);
    } catch (e) {
      _permCompleters.remove(token);
      debugPrint('TS: perm op $token send threw: $e');
      return _l10n?.permQueueFailed ?? 'Failed to queue the request';
    }
    if (!queued) {
      _permCompleters.remove(token);
      return _l10n?.permQueueFailed ?? 'Failed to queue the request';
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _permCompleters.remove(token);
      return _l10n?.permTimeout ?? 'The server did not answer in time';
    }
  }

  /// Add a client (database id) to a server group. null = success.
  Future<String?> addToServerGroup(int dbid, int sgid) =>
      _permOp((t) => TsNative.serverGroupAddClient(dbid, sgid, t));

  /// Remove a client from a server group. null = success.
  Future<String?> removeFromServerGroup(int dbid, int sgid) =>
      _permOp((t) => TsNative.serverGroupDelClient(dbid, sgid, t));

  /// Set a client's channel group in a channel. null = success.
  Future<String?> setChannelGroup(int dbid, int cgid, int channelId) =>
      _permOp((t) => TsNative.channelGroupSet(dbid, channelId, cgid, t));

  /// Clear a client's channel group in a channel. null = success.
  Future<String?> clearChannelGroup(int dbid, int channelId) =>
      _permOp((t) => TsNative.channelGroupClear(dbid, channelId, t));

  /// Grant a channel-scoped permission to a client. null = success.
  Future<String?> grantChannelPerm(
    int dbid,
    int cid,
    String permsid,
    int value,
  ) => _permOp((t) => TsNative.channelPermGrant(dbid, cid, permsid, value, t));

  /// Revoke a channel-scoped permission from a client. null = success.
  Future<String?> revokeChannelPerm(int dbid, int cid, String permsid) =>
      _permOp((t) => TsNative.channelPermRevoke(dbid, cid, permsid, t));

  /// Grant a server-wide permission to a client. null = success.
  Future<String?> grantServerPerm(int dbid, String permsid, int value) =>
      _permOp((t) => TsNative.serverPermGrant(dbid, permsid, value, t));

  /// Revoke a server-wide permission from a client. null = success.
  Future<String?> revokeServerPerm(int dbid, String permsid) =>
      _permOp((t) => TsNative.serverPermRevoke(dbid, permsid, t));

  void setVadThreshold(double threshold) {
    state = state.copyWith(vadThreshold: threshold);
    TsNative.setVadThreshold(threshold);
  }

  void setVadEnabled(bool enabled) {
    state = state.copyWith(vadEnabled: enabled);
    TsNative.setVadEnabled(enabled);
  }

  void setMicGain(double gain) {
    state = state.copyWith(micGain: gain);
    TsNative.setMicGain(gain);
    _prefs?.setDouble('mic_gain', gain);
  }

  void setClientVolume(int clientId, double volumeDb) {
    TsNative.setClientVolume(clientId, volumeDb);
    final newClients = state.clients.map((c) {
      if (c.id == clientId) return c.copyWith(volume: volumeDb);
      return c;
    }).toList();
    state = state.copyWith(clients: newClients);
    // Persist per-client volume to SharedPreferences keyed by the user UID,
    // so it survives reconnects and client ID reuse. Without a UID (client
    // just joined and the roster hasn't refreshed yet) the change only
    // applies for this session; _applySavedClientVolumes re-applies it once
    // the UID shows up.
    final client = newClients.where((c) => c.id == clientId).firstOrNull;
    final uid = client?.uid;
    if (uid != null && uid.isNotEmpty) {
      _prefs?.setDouble('client_volume_uid_$uid', volumeDb);
    }
  }

  /// Sets ([x]/[y] both non-null) or clears (either null) a client's 2D
  /// position relative to us, in meters (+x = right, +y = forward). The Rust
  /// mixer pans and distance-attenuates that client's audio accordingly.
  void setClientPosition(int clientId, double? x, double? y) {
    TsNative.setClientPosition(clientId, x, y);
    final newClients = state.clients.map((c) {
      if (c.id == clientId) return c.copyWith(position: (x: x, y: y));
      return c;
    }).toList();
    state = state.copyWith(clients: newClients);
    // Persist per-client position to SharedPreferences keyed by the user UID,
    // mirroring setClientVolume: without a UID yet (client just joined and the
    // roster hasn't refreshed) the change only applies for this session;
    // _applySavedClientPositions restores it once the UID shows up.
    final client = newClients.where((c) => c.id == clientId).firstOrNull;
    final uid = client?.uid;
    if (uid != null && uid.isNotEmpty) {
      if (x == null || y == null) {
        _prefs?.remove('client_pos_uid_$uid');
      } else {
        _prefs?.setString('client_pos_uid_$uid', '{"x":$x,"y":$y}');
      }
    }
  }

  /// Removes legacy `client_volume_<clid>` keys persisted by older builds.
  /// Volume persistence now uses `client_volume_uid_<uid>`.
  void _migrateLegacyVolumeKeys() {
    final prefs = _prefs;
    if (prefs == null) return;
    for (final key in prefs.getKeys().toList()) {
      if (!key.startsWith('client_volume_')) continue;
      final suffix = key.substring('client_volume_'.length);
      if (int.tryParse(suffix) != null) {
        prefs.remove(key);
      }
    }
  }

  /// Applies saved per-client volumes (keyed by user UID) to every client in
  /// the current roster whose saved volume differs from its current volume.
  /// Idempotent, so it is safe to call on every poll cycle: it covers the
  /// initial connect, clients that join later, and the window where a client's
  /// UID isn't known yet (the volume is re-applied once the UID appears).
  void _applySavedClientVolumes() {
    final prefs = _prefs;
    if (prefs == null) return;
    for (final client in state.clients) {
      final uid = client.uid;
      if (uid == null || uid.isEmpty) continue;
      final saved = prefs.getDouble('client_volume_uid_$uid');
      if (saved != null && (saved - client.volume).abs() > 0.001) {
        setClientVolume(client.id, saved);
      }
    }
  }

  /// Restores saved per-client positions (keyed by user UID) for roster
  /// clients not yet seen this session. Runs on every poll cycle: it covers
  /// the app-restart case (Rust state starts empty) and clients whose UID
  /// appears late. Each UID is applied at most once — afterwards live Rust
  /// state is authoritative, so the user's in-session edits always win.
  void _applySavedClientPositions() {
    final prefs = _prefs;
    if (prefs == null) return;
    for (final client in state.clients) {
      final uid = client.uid;
      if (uid == null || uid.isEmpty || _positionedUids.contains(uid)) continue;
      _positionedUids.add(uid);
      final raw = prefs.getString('client_pos_uid_$uid');
      if (raw == null) continue;
      try {
        final saved = jsonDecode(raw) as Map<String, dynamic>;
        final x = (saved['x'] as num?)?.toDouble();
        final y = (saved['y'] as num?)?.toDouble();
        if (x != null && y != null) {
          TsNative.setClientPosition(client.id, x, y);
        }
      } catch (_) {
        // Corrupt entry — drop it so it cannot break later polls either.
        prefs.remove('client_pos_uid_$uid');
      }
    }
  }
}

// ─── Server List Notifier ───────────────────────────────────────────

class ServerListNotifier extends Notifier<ServerListState> {
  @override
  ServerListState build() {
    _loadFromDisk();
    return const ServerListState();
  }

  Future<void> _loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList('servers') ?? [];
    final servers = data
        .map((s) => Server.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    state = state.copyWith(servers: servers, loading: false);
  }

  Future<void> _saveToDisk() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'servers',
      state.servers.map((s) => jsonEncode(s.toJson())).toList(),
    );
  }

  Future<void> addServer(Server server) async {
    state = state.copyWith(servers: [...state.servers, server]);
    await _saveToDisk();
  }

  Future<void> updateServer(Server server) async {
    final idx = state.servers.indexWhere((s) => s.id == server.id);
    if (idx < 0) return;
    final updated = [...state.servers];
    updated[idx] = server;
    state = state.copyWith(servers: updated);
    await _saveToDisk();
  }

  Future<void> removeServer(String serverId) async {
    state = state.copyWith(
      servers: state.servers.where((s) => s.id != serverId).toList(),
    );
    await _saveToDisk();
  }
}

// ─── Providers ──────────────────────────────────────────────────────

final tsConnectionProvider =
    NotifierProvider<TsConnectionNotifier, TsConnectionState>(
      TsConnectionNotifier.new,
    );

final serverListProvider =
    NotifierProvider<ServerListNotifier, ServerListState>(
      ServerListNotifier.new,
    );
