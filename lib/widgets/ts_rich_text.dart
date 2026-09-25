import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/generated/app_localizations.dart';
import '../utils/ts_bbcode.dart';

/// Rich chat text: renders TeamSpeak BBCode ([url], [b], [i], [u], [s],
/// [color], [size]) and auto-linked bare URLs from [parseTsText]. Link runs
/// are tappable — http(s) targets open in the external browser/app,
/// everything else shows a "could not open" snackbar (chat-supplied strings
/// never launch under other schemes).
///
/// The span tree and its gesture recognizers are rebuilt ONLY when the
/// inputs change, never per build: the chat panel rebuilds every poll tick /
/// mic-level update, and disposing a recognizer between pointer-down and
/// pointer-up would silently swallow the tap.
class TsRichText extends StatefulWidget {
  /// The message body to parse.
  final String text;

  /// Optional plain prefix rendered before the parsed spans (e.g. the
  /// "sender: " part of a chat line) — never parsed as markup.
  final String? prefix;
  final TextStyle? prefixStyle;

  /// Style the parsed text falls back to where the markup sets nothing.
  final TextStyle? baseStyle;
  final TextAlign textAlign;

  /// Test seam — intercepts the platform launch when set.
  @visibleForTesting
  static Future<bool> Function(Uri uri)? launchOverride;

  const TsRichText({
    super.key,
    required this.text,
    this.prefix,
    this.prefixStyle,
    this.baseStyle,
    this.textAlign = TextAlign.start,
  });

  @override
  State<TsRichText> createState() => _TsRichTextState();
}

class _TsRichTextState extends State<TsRichText> {
  TextSpan? _span;
  String? _cacheText;
  String? _cachePrefix;
  TextStyle? _cachePrefixStyle;
  TextStyle? _cacheBaseStyle;
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.baseStyle ?? DefaultTextStyle.of(context).style;
    // TextStyle implements ==, so parent rebuilds that recreate identical
    // styles reuse the cached span (and its live recognizers) unchanged.
    if (_span == null ||
        _cacheText != widget.text ||
        _cachePrefix != widget.prefix ||
        _cachePrefixStyle != widget.prefixStyle ||
        _cacheBaseStyle != base) {
      _disposeRecognizers();
      _span = _buildSpan(base);
      _cacheText = widget.text;
      _cachePrefix = widget.prefix;
      _cachePrefixStyle = widget.prefixStyle;
      _cacheBaseStyle = base;
    }
    return Text.rich(_span!, textAlign: widget.textAlign);
  }

  TextSpan _buildSpan(TextStyle base) {
    final spans = <InlineSpan>[];
    if (widget.prefix != null) {
      spans.add(
        TextSpan(text: widget.prefix, style: widget.prefixStyle ?? base),
      );
    }
    for (final segment in parseTsText(widget.text)) {
      // Links always render underlined; [s] strike combines with it.
      final underlined = segment.underline || segment.url != null;
      final decoration = segment.strike
          ? TextDecoration.combine([
              TextDecoration.lineThrough,
              if (underlined) TextDecoration.underline,
            ])
          : underlined
          ? TextDecoration.underline
          : null;
      var style = base.copyWith(
        fontWeight: segment.bold ? FontWeight.bold : null,
        fontStyle: segment.italic ? FontStyle.italic : null,
        decoration: decoration,
        color: segment.color,
        fontSize: segment.size,
      );
      if (segment.url != null) {
        style = style.copyWith(color: segment.color ?? Colors.lightBlueAccent);
        final recognizer = TapGestureRecognizer()
          ..onTap = () => _open(segment.url!);
        _recognizers.add(recognizer);
        spans.add(
          TextSpan(text: segment.text, style: style, recognizer: recognizer),
        );
      } else {
        spans.add(TextSpan(text: segment.text, style: style));
      }
    }
    return TextSpan(children: spans);
  }

  /// Opens a link target from a chat message. Only http(s) launches;
  /// failures degrade to a snackbar (best-effort, never throws).
  Future<void> _open(String url) async {
    // Capture the messenger/l10n synchronously — the context is still valid
    // here, and both outlive this widget if it unmounts mid-launch.
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failed = AppLocalizations.of(context).openLinkFailed;
    if (!isLaunchableTsUrl(url)) {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
      return;
    }
    final uri = Uri.parse(normalizeTsUrl(url));
    try {
      final launched = TsRichText.launchOverride != null
          ? await TsRichText.launchOverride!(uri)
          : await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) {
        messenger?.showSnackBar(SnackBar(content: Text(failed)));
      }
    } catch (_) {
      messenger?.showSnackBar(SnackBar(content: Text(failed)));
    }
  }
}
