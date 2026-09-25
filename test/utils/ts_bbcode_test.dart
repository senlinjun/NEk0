import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/utils/ts_bbcode.dart';

void main() {
  group('parseTsText', () {
    test('plain text stays a single unstyled segment', () {
      final segments = parseTsText('hello world');
      expect(segments, hasLength(1));
      expect(segments.single.text, 'hello world');
      expect(segments.single.url, isNull);
      expect(segments.single.bold, isFalse);
    });

    test('[url]content[/url] links the whole content', () {
      final segments = parseTsText('see [url]http://a.com/x[/url] now');
      expect(segments, hasLength(3));
      expect(segments[0].text, 'see ');
      expect(segments[1].text, 'http://a.com/x');
      expect(segments[1].url, 'http://a.com/x');
      expect(segments[2].text, ' now');
    });

    test('[url=target]text[/url] separates target and label', () {
      final segments = parseTsText('[url=http://a.com]click[/url]');
      expect(segments.single.text, 'click');
      expect(segments.single.url, 'http://a.com');
      // The label is not auto-relinked inside an explicit [url].
      final nested = parseTsText('[url=http://a.com]http://a.com[/url]');
      expect(nested, hasLength(1));
      expect(nested.single.url, 'http://a.com');
    });

    test('bare http(s) URLs are auto-linked', () {
      final segments = parseTsText('go https://b.com/x?y=1 end');
      expect(segments, hasLength(3));
      expect(segments[1].url, 'https://b.com/x?y=1');
      expect(segments[1].text, 'https://b.com/x?y=1');
    });

    test('bare www. hosts are linked for later https normalization', () {
      final segments = parseTsText('see www.example.com here');
      expect(segments[1].url, 'www.example.com');
      expect(normalizeTsUrl('www.example.com'), 'https://www.example.com');
    });

    test('style tags map to flags and nest', () {
      final segments = parseTsText('[b]bold [i]both[/i][/b]');
      expect(segments, hasLength(2));
      expect(segments[0].text, 'bold ');
      expect(segments[0].bold, isTrue);
      expect(segments[0].italic, isFalse);
      expect(segments[1].bold, isTrue);
      expect(segments[1].italic, isTrue);
    });

    test('underline and strikethrough flags', () {
      final segments = parseTsText('[u]u[/u] [s]s[/s]');
      expect(segments[0].underline, isTrue);
      expect(segments[1].text, ' ');
      expect(segments[2].strike, isTrue);
    });

    test('color accepts names and hex, ignores unknown values', () {
      final named = parseTsText('[color=red]r[/color]');
      expect(named.single.color, isNotNull);
      final hex = parseTsText('[color=#12AB34]h[/color]');
      expect(hex.single.color, isNotNull);
      // Unknown name keeps the surrounding style.
      final unknown = parseTsText('[color=nonsense]x[/color]');
      expect(unknown.single.color, isNull);
      expect(unknown.single.text, 'x');
    });

    test('size is clamped to 6..40', () {
      expect(parseTsText('[size=5]x[/size]').single.size, 6.0);
      expect(parseTsText('[size=100]x[/size]').single.size, 40.0);
      expect(parseTsText('[size=20]x[/size]').single.size, 20.0);
      // Non-numeric falls back to no size.
      expect(parseTsText('[size=big]x[/size]').single.size, isNull);
    });

    test('unclosed tags render literally', () {
      final segments = parseTsText('a [b]b [url]c');
      final text = segments.map((s) => s.text).join();
      expect(text, 'a [b]b [url]c');
      expect(segments.every((s) => s.url == null && !s.bold), isTrue);
    });

    test('unknown tags and stray closings render literally', () {
      final literal = parseTsText('[img=x]y[/img]');
      expect(literal.map((s) => s.text).join(), '[img=x]y[/img]');
      final stray = parseTsText('a[/b]b');
      expect(stray.map((s) => s.text).join(), 'a[/b]b');
    });

    test('markup inside a link still applies styling', () {
      final segments = parseTsText('[url=http://a.com][b]hot[/b][/url]');
      expect(segments.single.url, 'http://a.com');
      expect(segments.single.bold, isTrue);
    });
  });

  group('isLaunchableTsUrl', () {
    test('http and https pass, www normalizes to https', () {
      expect(isLaunchableTsUrl('http://a.com'), isTrue);
      expect(isLaunchableTsUrl('https://a.com/x'), isTrue);
      expect(isLaunchableTsUrl('www.a.com'), isTrue);
    });

    test('chat-supplied strings never launch other schemes', () {
      expect(isLaunchableTsUrl('ts3server://host?port=1'), isFalse);
      expect(isLaunchableTsUrl('javascript:alert(1)'), isFalse);
      expect(isLaunchableTsUrl('file:///etc/passwd'), isFalse);
      expect(isLaunchableTsUrl('teamspeak://host'), isFalse);
    });
  });
}
