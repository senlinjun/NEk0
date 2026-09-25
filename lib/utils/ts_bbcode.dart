import 'dart:ui' show Color;

/// Parses the BBCode-style rich text TeamSpeak servers/clients put into chat
/// messages ([url], [b], [i], [u], [s], [color], [size]) and auto-links bare
/// http(s) URLs, the way the official client does. Unknown or unclosed tags
/// are shown literally, like TS3 does.

/// One styled run of text. A run with [url] set is clickable.
class TsRichSegment {
  final String text;
  final String? url;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final Color? color;

  /// Font size in logical pixels, clamped to a sane range ([size] tag).
  final double? size;

  const TsRichSegment({
    required this.text,
    this.url,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.size,
  });
}

final RegExp _tagRegex = RegExp(
  r'\[(/?)(b|i|u|s|url|color|size)(?:=([^\[\]]+))?\]',
  caseSensitive: false,
);
final RegExp _bareUrlRegex = RegExp(
  r'https?://\S+|www\.\S+',
  caseSensitive: false,
);

/// Named colors the official client understands in [color=...].
const Map<String, Color> _namedColors = {
  'black': Color(0xFF000000),
  'white': Color(0xFFFFFFFF),
  'red': Color(0xFFFF0000),
  'green': Color(0xFF00CC00),
  'blue': Color(0xFF0066FF),
  'yellow': Color(0xFFFFFF00),
  'orange': Color(0xFFFF9900),
  'purple': Color(0xFF993399),
  'pink': Color(0xFFFF00FF),
  'brown': Color(0xFFA52A2A),
  'gray': Color(0xFF808080),
  'grey': Color(0xFF808080),
};

/// Splits [input] into styled segments. Never returns empty output for
/// non-empty input — unrecognized markup stays visible as plain text.
List<TsRichSegment> parseTsText(String input) {
  final segments = <TsRichSegment>[];
  _parse(input, const _Style(), segments);
  return segments;
}

void _parse(String text, _Style style, List<TsRichSegment> out) {
  var pos = 0;
  for (final match in _tagRegex.allMatches(text)) {
    // Matches are collected upfront — anything before [pos] was already
    // consumed by an inner region (e.g. the [/b] of a handled [b]...[/b]).
    if (match.start < pos) continue;
    if (match.start > pos) {
      _emitText(text.substring(pos, match.start), style, out);
    }
    final isClosing = match.group(1) == '/';
    final tag = match.group(2)!.toLowerCase();
    final arg = match.group(3);

    if (isClosing) {
      // A closing tag without an opener renders literally.
      _emitText(match.group(0)!, style, out);
      pos = match.end;
      continue;
    }
    switch (tag) {
      case 'b':
      case 'i':
      case 'u':
      case 's':
        final close = _findClosingTag(text, match.end, tag);
        if (close == null) {
          _emitText(match.group(0)!, style, out);
          pos = match.end;
          break;
        }
        _parse(
          text.substring(match.end, close.start),
          style.withFlag(tag),
          out,
        );
        pos = close.end;
      case 'url':
        final close = _findClosingTag(text, match.end, 'url');
        if (close == null) {
          _emitText(match.group(0)!, style, out);
          pos = match.end;
          break;
        }
        // [url]target[/url] uses the content as the target; [url=t]text[/url]
        // uses the argument.
        final href = (arg?.trim().isNotEmpty ?? false)
            ? arg!.trim()
            : text.substring(match.end, close.start).trim();
        if (href.isEmpty) {
          _emitText(text.substring(match.start, close.end), style, out);
        } else {
          _parse(
            text.substring(match.end, close.start),
            style.withUrl(href),
            out,
          );
        }
        pos = close.end;
      case 'color':
        final close = _findClosingTag(text, match.end, 'color');
        if (close == null) {
          _emitText(match.group(0)!, style, out);
          pos = match.end;
          break;
        }
        _parse(
          text.substring(match.end, close.start),
          style.withColor(_parseColor(arg)),
          out,
        );
        pos = close.end;
      case 'size':
        final close = _findClosingTag(text, match.end, 'size');
        if (close == null) {
          _emitText(match.group(0)!, style, out);
          pos = match.end;
          break;
        }
        _parse(
          text.substring(match.end, close.start),
          style.withSize(_parseSize(arg)),
          out,
        );
        pos = close.end;
      default:
        // Unreachable — the regex only matches the tags above.
        _emitText(match.group(0)!, style, out);
        pos = match.end;
    }
  }
  if (pos < text.length) {
    _emitText(text.substring(pos), style, out);
  }
}

/// Finds the first case-insensitive [tag] closing tag at or after [from],
/// returned as (start, end) offsets into [text].
({int start, int end})? _findClosingTag(String text, int from, String tag) {
  final match = RegExp(
    r'\[/' + tag + r'\]',
    caseSensitive: false,
  ).firstMatch(text.substring(from));
  if (match == null) return null;
  return (start: from + match.start, end: from + match.end);
}

void _emitText(String text, _Style style, List<TsRichSegment> out) {
  if (text.isEmpty) return;
  if (style.url != null) {
    // Inside an explicit [url] tag the whole content is the link — no
    // additional auto-linking.
    out.add(style.toSegment(text));
    return;
  }
  // Auto-link bare URLs in plain runs, like the official client.
  var pos = 0;
  for (final match in _bareUrlRegex.allMatches(text)) {
    if (match.start > pos) {
      out.add(style.toSegment(text.substring(pos, match.start)));
    }
    out.add(style.withUrl(match.group(0)!).toSegment(match.group(0)!));
    pos = match.end;
  }
  if (pos < text.length) {
    out.add(style.toSegment(text.substring(pos)));
  }
}

/// [color=red] / [color=#rrggbb] — null for anything unrecognized (renders
/// with the surrounding style, like TS3).
Color? _parseColor(String? arg) {
  if (arg == null) return null;
  final value = arg.trim().toLowerCase();
  final named = _namedColors[value];
  if (named != null) return named;
  final hex = RegExp(r'^#?([0-9a-f]{6})$').firstMatch(value);
  if (hex == null) return null;
  final rgb = int.parse(hex.group(1)!, radix: 16);
  return Color(0xFF000000 | rgb);
}

/// [size=N] in pixels — clamped so a message cannot render microscopic or
/// screen-filling text.
double? _parseSize(String? arg) {
  if (arg == null) return null;
  final value = int.tryParse(arg.trim());
  if (value == null) return null;
  return value.clamp(6, 40).toDouble();
}

/// Normalizes a link target from a message for launching: bare `www.`
/// hosts get an https scheme prepended.
String normalizeTsUrl(String url) {
  final trimmed = url.trim();
  return trimmed.toLowerCase().startsWith('www.')
      ? 'https://$trimmed'
      : trimmed;
}

/// Only http(s) links ever launch — chat-supplied strings must not reach
/// other schemes (ts3server:, file:, javascript:, ...).
bool isLaunchableTsUrl(String url) {
  final uri = Uri.tryParse(normalizeTsUrl(url));
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

/// Immutable style frame for the recursive parser.
class _Style {
  final String? url;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final Color? color;
  final double? size;

  const _Style({
    this.url,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.color,
    this.size,
  });

  _Style withFlag(String tag) => _Style(
    url: url,
    bold: bold || tag == 'b',
    italic: italic || tag == 'i',
    underline: underline || tag == 'u',
    strike: strike || tag == 's',
    color: color,
    size: size,
  );

  _Style withUrl(String url) => _Style(
    url: url,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color,
    size: size,
  );

  _Style withColor(Color? color) => _Style(
    url: url,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color ?? this.color,
    size: size,
  );

  _Style withSize(double? size) => _Style(
    url: url,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color,
    size: size ?? this.size,
  );

  TsRichSegment toSegment(String text) => TsRichSegment(
    text: text,
    url: url,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    color: color,
    size: size,
  );
}
