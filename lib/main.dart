import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'l10n/generated/app_localizations.dart';
import 'models/app_locale.dart';
import 'models/background_settings.dart';
import 'screens/home_screen.dart';
import 'services/sfx_pack_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Re-apply the active voice pack persisted in the private documents
  // directory (built-in samples remain active without one).
  await SfxPackService.init();
  runApp(const ProviderScope(child: TeamSpeakApp()));
}

class TeamSpeakApp extends ConsumerWidget {
  const TeamSpeakApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    return MaterialApp(
      title: 'TeamSpeak',
      debugShowCheckedModeBanner: false,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: ThemeData.dark().copyWith(
        // Scaffolds paint nothing themselves — the app-wide background layer
        // in [builder] below shows through. Without a custom image that layer
        // is the original solid color, so the look is unchanged.
        scaffoldBackgroundColor: Colors.transparent,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF16213E),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        cardColor: const Color(0xFF1A1A2E),
        dividerColor: const Color(0xFF2A2A4A),
      ),
      // App-wide custom background: base color → optional image → dim
      // overlay → real content. Cards, app bars and dialogs stay opaque so
      // text remains readable on light wallpapers.
      builder: (context, child) {
        return Consumer(
          builder: (context, ref, _) {
            final settings = ref.watch(backgroundSettingsProvider);
            final path = settings.path;
            return Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF0F0F23)),
                if (path != null)
                  Opacity(
                    opacity: settings.opacity,
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      cacheWidth: _backgroundCacheWidth(context),
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                if (path != null)
                  ColoredBox(color: Color.fromRGBO(0, 0, 0, settings.dim)),
                if (child != null) child,
              ],
            );
          },
        );
      },
      home: const HomeScreen(),
    );
  }

  /// Decode the wallpaper at roughly screen resolution instead of full
  /// camera size (a 12 MP photo would otherwise sit decoded in memory).
  static int _backgroundCacheWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final px = (mq.size.width * mq.devicePixelRatio).round();
    if (px < 720) return 720;
    if (px > 1440) return 1440;
    return px;
  }
}
