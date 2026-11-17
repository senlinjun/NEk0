import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'channel.dart';
import 'client.dart';

// Roster parsing/merging helpers shared by the `connected` /
// `channels_updated` event handlers and the 200 ms poll. Pure functions (no
// FFI) so the recovery policy stays unit-testable.

// The native getters report "[]" for three very different situations: not
// connected, the roster mirror is not primed yet (the login dumps can land
// late, and univox clears the mirror while rebuilding it around a temporary
// reconnect), and — in theory — a genuinely empty roster. Treating every
// "[]" as authoritative is what let a transient empty snapshot erase the
// channel tree on a quiet server with nothing left to repair it.

/// Parses a `ts_get_channels()` JSON array. One malformed row is skipped
/// with a debug print instead of failing the whole batch — the previous
/// `.map(...).toList()` threw, the event handler aborted mid-case and the
/// connection state machine stalled.
List<TsChannel> parseChannelRoster(String json) {
  try {
    final rows = jsonDecode(json) as List;
    final channels = <TsChannel>[];
    for (final row in rows) {
      try {
        channels.add(TsChannel.fromJson(row as Map<String, dynamic>));
      } catch (e) {
        debugPrint('roster: skipping bad channel row: $e');
      }
    }
    return channels;
  } catch (e) {
    debugPrint('roster: channel JSON parse failed: $e');
    return const [];
  }
}

/// Same per-row resilience for a `ts_get_clients()` JSON array.
List<TsClient> parseClientRoster(String json) {
  try {
    final rows = jsonDecode(json) as List;
    final clients = <TsClient>[];
    for (final row in rows) {
      try {
        clients.add(TsClient.fromJson(row as Map<String, dynamic>));
      } catch (e) {
        debugPrint('roster: skipping bad client row: $e');
      }
    }
    return clients;
  } catch (e) {
    debugPrint('roster: client JSON parse failed: $e');
    return const [];
  }
}

/// Every TS3 server has at least one top-level channel, so a list without
/// roots is a partial/late snapshot. Clients render nested under channels,
/// which is why a rootless list would hide every user in the UI.
bool hasUsableChannels(List<TsChannel> channels) =>
    channels.isNotEmpty && channels.any((c) => c.parentId == 0);

/// Merge policy for channel snapshots: an incoming snapshot that is empty or
/// rootless never replaces a currently usable tree.
List<TsChannel> mergeChannelRoster(
  List<TsChannel> current,
  List<TsChannel> incoming,
) {
  if (!hasUsableChannels(incoming) && hasUsableChannels(current)) {
    return current;
  }
  return incoming;
}

/// Merge policy for client snapshots: same idea — a usable list is never
/// downgraded to empty.
List<TsClient> mergeClientRoster(
  List<TsClient> current,
  List<TsClient> incoming,
) {
  if (incoming.isEmpty && current.isNotEmpty) {
    return current;
  }
  return incoming;
}
