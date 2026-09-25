import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:NEk0/l10n/generated/app_localizations.dart';
import 'package:NEk0/widgets/ts_rich_text.dart';

/// Widget tests for the link-tap path. The chat panel rebuilds frequently
/// while connected (mic RMS every 50ms, poll-driven roster refreshes), so
/// the critical regression here is a rebuild landing BETWEEN pointer-down
/// and pointer-up: with per-build recognizer disposal the tap silently
/// dies, with the cached-span lifecycle it must still launch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TsRichText.launchOverride = (uri) async => true;
  });

  tearDown(() {
    TsRichText.launchOverride = null;
  });

  /// Pumps one TsRichText with [text] and returns the captured outer
  /// setState for forced parent rebuilds.
  Future<StateSetter> pumpText(WidgetTester tester, String text) async {
    late StateSetter setOuterState;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setOuterState = setState;
              return TsRichText(text: text);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return setOuterState;
  }

  /// Starts a gesture at the center of the character range [start, end) of
  /// the single-line paragraph. Both the widget layout and the measuring
  /// TextPainter lay the same short text out on one line, so the x offsets
  /// match.
  Future<TestGesture> tapSpan(WidgetTester tester, int start, int end) async {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byType(RichText),
    );
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
    )..layout();
    final xStart = painter
        .getOffsetForCaret(TextPosition(offset: start), Rect.zero)
        .dx;
    final xEnd = painter
        .getOffsetForCaret(TextPosition(offset: end), Rect.zero)
        .dx;
    final local = Offset((xStart + xEnd) / 2, painter.height / 2);
    return tester.startGesture(paragraph.localToGlobal(local));
  }

  testWidgets('tapping a link launches the parsed target', (tester) async {
    // 'see click' — the 'click' run (offsets 4..9) links to http://a.com.
    await pumpText(tester, 'see [url=http://a.com]click[/url]');
    Uri? launched;
    TsRichText.launchOverride = (uri) async {
      launched = uri;
      return true;
    };
    final gesture = await tapSpan(tester, 4, 9);
    await gesture.up();
    await tester.pump();
    expect(launched, Uri.parse('http://a.com'));
  });

  testWidgets('a parent rebuild between down and up does not kill the tap', (
    tester,
  ) async {
    final setOuterState = await pumpText(
      tester,
      'see [url=http://a.com]click[/url]',
    );
    Uri? launched;
    TsRichText.launchOverride = (uri) async {
      launched = uri;
      return true;
    };
    final gesture = await tapSpan(tester, 4, 9);
    // The 50ms mic-level update / poll tick lands right here in production.
    setOuterState(() {});
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(launched, Uri.parse('http://a.com'));
  });

  testWidgets('non-http(s) targets never launch', (tester) async {
    await pumpText(tester, '[url]ts3server://host[/url]');
    Uri? launched;
    TsRichText.launchOverride = (uri) async {
      launched = uri;
      return true;
    };
    final gesture = await tapSpan(tester, 0, 16);
    await gesture.up();
    await tester.pump();
    expect(launched, isNull);
  });
}
