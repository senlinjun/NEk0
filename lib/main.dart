import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'l10n/generated/app_localizations.dart';
import 'models/app_locale.dart';
import 'models/background_settings.dart';
import 'screens/home_screen.dart';
import 'services/sfx_pack_service.dart';
import 'widgets/desktop_window_scope.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Re-apply the active voice pack persisted in the private documents
  // directory (built-in samples remain active without one).
  await SfxPackService.init();
  // Desktop: intercept the window close button so DesktopWindowScope can
  // ask whether to quit or hide to the tray. The close handling itself
  // needs providers, so it lives in that widget once the app is running.
  if (!Platform.isAndroid) {
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }
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
        // Page transitions fade routes over an opaque scrim by default
        // (FadeForwards on Android pads with ColorScheme.surface for the
        // whole animation, Zoom on desktop draws a 60% surface tint), which
        // would hide the app-wide background until the animation completes.
        // Transparent transition backgrounds keep the wallpaper visible while
        // pages animate; the background layer's base color below the navigator
        // still prevents any black flash between two fading pages.
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            // fallbackColor only affects programmatic push/pop, which the
            // predictive back builder serves through its FadeForwards
            // fallback; the actual back-gesture animation has no scrim.
            TargetPlatform.android: PredictiveBackPageTransitionsBuilder(
              fallbackColor: Colors.transparent,
            ),
            // Zoom's scrim is applied via withOpacity and can therefore not
            // be made fully transparent — desktop uses the fade-forwards
            // transition instead (slide + fade, matching Android).
            TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(
              backgroundColor: Colors.transparent,
            ),
            TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(
              backgroundColor: Colors.transparent,
            ),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
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
                // Own repaint boundary so the static background keeps a
                // stable retained raster layer: Impeller has been seen to
                // drop the wallpaper texture after route transitions until
                // some later rebuild re-rasterizes the root layer.
                RepaintBoundary(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Color(0xFF0F0F23)),
                      if (path != null)
                        Image.file(
                          File(path),
                          fit: BoxFit.cover,
                          // Baked into the image paint itself — a wrapping
                          // Opacity widget would add a separate opacity
                          // layer that Impeller can drop after transitions.
                          opacity: AlwaysStoppedAnimation(settings.opacity),
                          cacheWidth: _backgroundCacheWidth(context),
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                        ),
                      if (path != null)
                        ColoredBox(
                          color: Color.fromRGBO(0, 0, 0, settings.dim),
                        ),
                    ],
                  ),
                ),
                if (child != null) child,
              ],
            );
          },
        );
      },
      home: const DesktopWindowScope(child: HomeScreen()),
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
