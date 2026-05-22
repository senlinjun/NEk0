import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/channel.dart';
import '../models/client.dart';
import '../models/chat_message.dart';
import '../models/server.dart';
import '../services/ts_ffi.dart';
import '../services/audio_service.dart';
import '../services/foreground_service.dart';

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
  final String? error;
  final List<String> diagMessages;
  final bool voiceActive;
  final bool inputMuted;
  final bool outputMuted;
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
    this.error,
    this.diagMessages = const [],
    this.voiceActive = false,
    this.inputMuted = false,
    this.outputMuted = false,
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
    String? error,
    List<String>? diagMessages,
    bool? voiceActive,
    bool? inputMuted,
    bool? outputMuted,
    bool? pttMode,
    bool? pttPressed,
    bool? vadEnabled,
    double? vadThreshold,
    double? micGain,
    double? micRms,
  }) =>
      TsConnectionState(
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
        error: error,
        diagMessages: diagMessages ?? this.diagMessages,
        voiceActive: voiceActive ?? this.voiceActive,
        inputMuted: inputMuted ?? this.inputMuted,
        outputMuted: outputMuted ?? this.outputMuted,
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
  SharedPreferences? _prefs; // cached for synchronous saves

  @override
  TsConnectionState build() {
    ForegroundService.init();
    ForegroundService.onToggleMute = (bool inputMuted) {
      if (state.inputMuted != inputMuted) {
        toggleInputMute();
      }
    };
    ForegroundService.onNotificationDisconnect = () {
      disconnect();
    };

    ref.onDispose(() {
      _pollTimer?.cancel();
      ForegroundService.onToggleMute = null;
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
  }) async {
    debugPrint('TS: connect($address, $nickname, ch=$channel)');
    state = state.copyWith(connecting: true, error: null);

    // Push persisted identity to Rust before connecting
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs; // cache for synchronous saves
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

    // Call Rust FFI - starts async connection in background
    final resultJson = TsNative.connect(address, nickname, channel: channel, password: password);
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
        _handleEvent(event);
      }
      // Poll voice activity for UI indicator
      final va = TsNative.isVoiceActive();
      if (va != state.voiceActive) {
        state = state.copyWith(voiceActive: va);
        _refreshNotification();
      }
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
        );

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
        ForegroundService.start(title: state.serverName, text: _currentChannelName, mic: false, inputMuted: state.inputMuted);
        _saveIdentity();
        break;

      case 'disconnected':
        if (state.connecting) break; // stale event from previous connection, ignore
        _pollTimer?.cancel();
        _audioService?.stop();
        _audioService = null;
        ForegroundService.stop();
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
        state = state.copyWith(
          diagMessages: [...state.diagMessages, msg],
        );
        break;

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
    }
  }

  Future<void> disconnect() async {
    debugPrint('TS: disconnect called, connected=${state.connected}');
    if (!state.connected && !state.connecting) return;
    _audioService?.stop();
    _audioService = null;
    _micEnabled = false;
    ForegroundService.stop();
    _pollTimer?.cancel();
    TsNative.disconnect();
    // Keep polling for ~3 seconds to capture Rust disconnect diag messages
    state = state.copyWith(connecting: false, connected: false);
  }

  Future<void> sendChannelMessage(String text) async {
    if (!state.connected || text.isEmpty) return;
    debugPrint('TS: sendChannelMessage(cid=${state.selectedChannelId}, len=${text.length})');
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

  void selectChannel(int channelId) {
    debugPrint('TS: selectChannel($channelId)');
    state = state.copyWith(selectedChannelId: channelId);
    TsNative.moveToChannel(channelId);
  }

  // ─── Voice control flow ──────────────────────────────────────────

  String get _currentChannelName {
    final own = state.clients.where((c) => c.id == state.ownClientId).firstOrNull;
    if (own == null) return '';
    return state.channels.where((c) => c.id == own.channelId).firstOrNull?.name ?? '';
  }

  void _refreshNotification({bool mic = false}) {
    var text = _currentChannelName;
    if (!state.inputMuted || state.voiceActive) {
      text = '$text \u2014 Speaking';
    }
    ForegroundService.update(title: state.serverName, text: text, mic: mic, inputMuted: state.inputMuted);
  }

  /// Diagram: Start -> PTT? -> pushed? -> send : mute? -> send : nothing
  bool get _shouldMicBeActive {
    if (state.pttMode) return state.pttPressed;
    return !state.inputMuted;
  }

  void _updateMicState() {
    if (_audioService == null) return;
    final should = _shouldMicBeActive;
    if (should && !_micEnabled) {
      _audioService!.enableMic().then((granted) {
        if (granted) _refreshNotification(mic: true);
      });
      _micEnabled = true;
    } else if (!should && _micEnabled) {
      _audioService!.disableMic();
      _micEnabled = false;
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
  }

  void toggleOutputMute() {
    final newMuted = !state.outputMuted;
    state = state.copyWith(outputMuted: newMuted);
    TsNative.setMuted(input: state.inputMuted, output: newMuted);
  }

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
