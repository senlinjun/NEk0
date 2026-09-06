import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-custom background image preferences. The image itself is picked and
/// stored by [BackgroundService] (services/background_service.dart); this
/// provider holds the rendering knobs consumed by the app-wide background
/// layer in main.dart and persists them across restarts. Values are loaded
/// lazily like the locale provider: until the first disk read completes the
/// defaults are in effect.
class BackgroundSettingsState {
  /// Absolute path of the custom background image, or null when the app uses
  /// its built-in solid colors.
  final String? path;

  /// Darkening overlay opacity (0–0.8) applied on top of the background
  /// image so light wallpapers keep text readable.
  final double dim;

  /// Opacity (0.1–1.0) of the background image itself — lower values fade
  /// the picture toward the base color for a subtler look.
  final double opacity;

  const BackgroundSettingsState({
    this.path,
    this.dim = 0.4,
    this.opacity = 1.0,
  });
}

class BackgroundSettingsNotifier extends Notifier<BackgroundSettingsState> {
  static const _kPath = 'custom_bg_path';
  static const _kDim = 'custom_bg_dim';
  static const _kOpacity = 'custom_bg_opacity';

  bool _loaded = false;

  @override
  BackgroundSettingsState build() {
    _load();
    return const BackgroundSettingsState();
  }

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    state = BackgroundSettingsState(
      path: prefs.getString(_kPath),
      dim: prefs.getDouble(_kDim) ?? 0.4,
      opacity: prefs.getDouble(_kOpacity) ?? 1.0,
    );
  }

  /// Shows the image at [path]; null falls back to the built-in colors.
  /// BackgroundService handles the file itself.
  Future<void> setPath(String? path) async {
    state = BackgroundSettingsState(
      path: path,
      dim: state.dim,
      opacity: state.opacity,
    );
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove(_kPath);
    } else {
      await prefs.setString(_kPath, path);
    }
  }

  Future<void> setDim(double dim) async {
    final clamped = dim.clamp(0.0, 0.8);
    state = BackgroundSettingsState(
      path: state.path,
      dim: clamped,
      opacity: state.opacity,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDim, clamped);
  }

  Future<void> setOpacity(double opacity) async {
    final clamped = opacity.clamp(0.1, 1.0);
    state = BackgroundSettingsState(
      path: state.path,
      dim: state.dim,
      opacity: clamped,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kOpacity, clamped);
  }
}

final backgroundSettingsProvider =
    NotifierProvider<BackgroundSettingsNotifier, BackgroundSettingsState>(
      BackgroundSettingsNotifier.new,
    );
