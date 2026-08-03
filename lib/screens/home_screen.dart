import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/server.dart';
import '../models/ts_state.dart';
import '../services/ota_service.dart';
import '../widgets/server_form_dialog.dart';
import '../widgets/spotlight_tour.dart';
import 'server_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final GlobalKey _addServerKey = GlobalKey();
  bool _guideChecked = false;
  bool _otaChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoShowGuide());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeAutoCheckUpdate(),
    );
  }

  /// Show the one-step "Add server" guide on first launch only.
  Future<void> _maybeAutoShowGuide() async {
    if (_guideChecked) return;
    _guideChecked = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('tour_home_shown') ?? false) return;
    await prefs.setBool('tour_home_shown', true);
    if (!mounted) return;
    await showSpotlightTour(context, [_homeStep()]);
  }

  /// Silent OTA check on launch (once per session, only if enabled).
  Future<void> _maybeAutoCheckUpdate() async {
    if (_otaChecked) return;
    _otaChecked = true;
    final settings = OtaSettings();
    await settings.load();
    if (!settings.enabled || !mounted) return;
    final info = await OtaService.checkForUpdate(settings.source);
    if (info == null || !mounted) return;
    await showUpdateDialog(context, info);
  }

  Future<void> _showGuide() async {
    await showSpotlightTour(context, [_homeStep()]);
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }

  TourStep _homeStep() => TourStep(
    title: 'Add your server',
    description:
        'Tap + to add a TeamSpeak server, then tap it to '
        'connect and start talking.',
    targetKey: _addServerKey,
  );

  @override
  Widget build(BuildContext context) {
    final serverState = ref.watch(serverListProvider);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F23),
      appBar: AppBar(
        title: const Text('NEk0'),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: Colors.white70),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.help_outline, color: Colors.white70),
            tooltip: 'Guide',
            onPressed: _showGuide,
          ),
          IconButton(
            key: _addServerKey,
            icon: const Icon(Icons.add),
            tooltip: 'Add Server',
            onPressed: () => _addOrEditServer(context, ref),
          ),
        ],
      ),
      body: SafeArea(
        child: serverState.loading
            ? const Center(child: CircularProgressIndicator(color: Colors.blue))
            : serverState.servers.isEmpty
            ? _buildEmpty(context, ref)
            : ListView.separated(
                padding: const EdgeInsets.all(8),
                itemCount: serverState.servers.length,
                separatorBuilder: (_, __) => const SizedBox(height: 4),
                itemBuilder: (context, index) =>
                    _buildServerTile(context, ref, serverState.servers[index]),
              ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dns, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No servers added',
            style: TextStyle(color: Colors.grey, fontSize: 16),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _addOrEditServer(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('Add Server'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
          ),
        ],
      ),
    );
  }

  Widget _buildServerTile(BuildContext context, WidgetRef ref, Server server) {
    return Card(
      color: const Color(0xFF1A1A2E),
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.dns, color: Colors.blue),
        title: Text(
          server.name,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        subtitle: Text(
          '${server.address} (${server.nickname})',
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.grey),
          onSelected: (action) {
            switch (action) {
              case 'edit':
                _addOrEditServer(context, ref, existing: server);
                break;
              case 'delete':
                _deleteServer(context, ref, server);
                break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: () => _connectTo(context, ref, server),
      ),
    );
  }

  Future<void> _addOrEditServer(
    BuildContext context,
    WidgetRef ref, {
    Server? existing,
  }) async {
    final result = await showDialog<Server>(
      context: context,
      builder: (_) => ServerFormDialog(existing: existing),
    );
    if (result == null) return;

    if (existing != null) {
      ref.read(serverListProvider.notifier).updateServer(result);
    } else {
      ref.read(serverListProvider.notifier).addServer(result);
    }
  }

  Future<void> _deleteServer(
    BuildContext context,
    WidgetRef ref,
    Server server,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: const Text(
          'Delete Server?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Remove "${server.name}" from bookmarks?',
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ref.read(serverListProvider.notifier).removeServer(server.id);
  }

  Future<void> _connectTo(
    BuildContext context,
    WidgetRef ref,
    Server server,
  ) async {
    final conn = ref.read(tsConnectionProvider.notifier);
    await conn.connect(
      address: server.address,
      nickname: server.nickname,
      channel: server.channel,
      password: server.password,
    );

    if (context.mounted) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const ServerScreen()))
          .then((error) {
            if (error is String && error.isNotEmpty && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(error), backgroundColor: Colors.red),
              );
            }
          });
    }
  }
}
