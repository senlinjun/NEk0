import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/generated/app_localizations.dart';

/// In-app language selection: "system" (follow the device language), "en",
/// "zh". Persisted in SharedPreferences. Also caches the loaded
/// [AppLocalizations] so code without a BuildContext (e.g. the connection
/// notifier) can read localized notification strings.
class LocaleNotifier extends Notifier<Locale?> {
  static const _kLocalePref = 'locale';
  static const _system = 'system';

  AppLocalizations? _localizations;
  bool _loaded = false;

  /// Localized strings for the current language (null until first load).
  AppLocalizations? get localizations => _localizations;

  @override
  Locale? build() {
    _init();
    // null = follow the system locale until the saved preference is loaded.
    return null;
  }

  Future<void> _init() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    await _apply(prefs.getString(_kLocalePref) ?? _system);
  }

  Future<void> _apply(String code) async {
    final Locale? fixed = switch (code) {
      'en' => const Locale('en'),
      'zh' => const Locale('zh'),
      _ => null,
    };
    final effective = fixed ?? _systemLocale();
    _localizations = await AppLocalizations.delegate.load(effective);
    state = fixed;
  }

  Future<void> setLanguage(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLocalePref, code);
    await _apply(code);
  }

  Locale _systemLocale() {
    final sys = WidgetsBinding.instance.platformDispatcher.locale;
    return sys.languageCode == 'zh' ? const Locale('zh') : const Locale('en');
  }
}

final localeProvider = NotifierProvider<LocaleNotifier, Locale?>(
  LocaleNotifier.new,
);
