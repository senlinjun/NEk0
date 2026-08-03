import 'package:flutter/material.dart';

/// One step of the spotlight guide: highlights the widget bound to
/// [targetKey] with a cutout in the scrim and shows a tooltip bubble.
class TourStep {
  const TourStep({
    required this.targetKey,
    required this.title,
    required this.description,
    this.padding = 12,
  });

  final GlobalKey targetKey;
  final String title;
  final String description;

  /// Extra space around the highlighted widget (size of the "hole").
  final double padding;
}

/// Pushes a full-screen spotlight guide over the current screen. Returns when
/// the guide is dismissed (Done/Skip) or when the underlying route pops.
Future<void> showSpotlightTour(BuildContext context, List<TourStep> steps) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 220),
      reverseTransitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => _SpotlightTour(steps: steps),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class _SpotlightTour extends StatefulWidget {
  const _SpotlightTour({required this.steps});

  final List<TourStep> steps;

  @override
  State<_SpotlightTour> createState() => _SpotlightTourState();
}

class _SpotlightTourState extends State<_SpotlightTour>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  Rect? _target;
  Rect? _previous;

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  TourStep get _step => widget.steps[_index];

  @override
  void initState() {
    super.initState();
    _anim.forward();
    _scheduleMeasure();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  Rect? _measure() {
    final ctx = _step.targetKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Re-measure the target on every frame so the cutout follows it even while
  /// the underlying screen is still animating in (route transitions, layout
  /// shifts, rotation). No-op when nothing moved.
  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final r = _measure();
      if (r != null && r != _target) {
        setState(() => _target = r);
      }
      _scheduleMeasure();
    });
  }

  void _next() {
    if (_index >= widget.steps.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _previous = _target;
      _index += 1;
    });
    _anim.forward(from: 0);
  }

  Rect? _cutoutRect(double t) {
    final target = _target;
    if (target == null) return null;
    final p = _step.padding;
    final from = (_previous ?? target).inflate(p);
    final to = target.inflate(p);
    return t < 1.0 ? Rect.lerp(from, to, Curves.easeOutCubic.transform(t)) : to;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return GestureDetector(
      // Consume taps anywhere except the bubble buttons, so the covered
      // screen cannot be reached while the tour is up.
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final t = _anim.value;
          final cutout = _cutoutRect(t);
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _TourPainter(cutout: cutout, opacity: t),
                ),
              ),
              if (cutout != null) _buildBubble(size, cutout),
              Positioned(left: 0, right: 0, bottom: 28, child: _buildDots()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBubble(Size size, Rect cutout) {
    final bubbleWidth = size.width < 272.0 ? size.width - 32.0 : 240.0;
    final left = (cutout.center.dx - bubbleWidth / 2).clamp(
      16.0,
      size.width - bubbleWidth - 16.0,
    );
    final above = cutout.top > 190;
    // Caret (arrow) pointing at the highlighted widget, horizontally aligned
    // with the hole so a small target next to others is unambiguous.
    final caretX = (cutout.center.dx - left - 7.0).clamp(
      18.0,
      bubbleWidth - 18.0,
    );
    final caret = SizedBox(
      width: double.infinity,
      child: Align(
        alignment: Alignment(
          (-1.0 + (2.0 * caretX) / bubbleWidth).clamp(-1, 1),
          0,
        ),
        child: CustomPaint(
          size: const Size(14, 7),
          painter: _CaretPainter(
            color: const Color(0xFF1A1A2E),
            // Bubble above the hole → arrow at the bubble's bottom edge,
            // pointing down toward the hole.
            pointingUp: !above,
          ),
        ),
      ),
    );
    final body = Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF2A2A4A)),
        boxShadow: const [
          BoxShadow(
            color: Colors.black54,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _step.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _step.description,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Skip', style: TextStyle(color: Colors.grey)),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _next,
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(
                  _index == widget.steps.length - 1 ? 'Done' : 'Next',
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return Positioned(
      left: left,
      width: bubbleWidth,
      top: above ? null : cutout.bottom + 12,
      bottom: above ? size.height - cutout.top + 12 : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // Caret sits on the edge facing the hole.
        children: above ? [body, caret] : [caret, body],
      ),
    );
  }

  Widget _buildDots() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(widget.steps.length, (i) {
        final active = i == _index;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 18 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? Colors.blue : Colors.white24,
            borderRadius: BorderRadius.circular(4),
          ),
        );
      }),
    );
  }
}

class _TourPainter extends CustomPainter {
  _TourPainter({required this.cutout, required this.opacity});

  final Rect? cutout;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Colors.black.withValues(alpha: 0.62 * opacity),
    );
    final c = cutout;
    if (c == null) return;
    final rrect = RRect.fromRectAndRadius(c, const Radius.circular(14));
    // Punch a hole through the scrim (works only inside saveLayer).
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRRect(rrect, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.lightBlueAccent.withValues(alpha: 0.9 * opacity),
    );
  }

  @override
  bool shouldRepaint(_TourPainter oldDelegate) =>
      oldDelegate.cutout != cutout || oldDelegate.opacity != opacity;
}

/// Small triangle that points from the bubble toward the highlighted widget.
class _CaretPainter extends CustomPainter {
  _CaretPainter({required this.color, required this.pointingUp});

  final Color color;
  final bool pointingUp;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, pointingUp ? size.height : 0)
      ..lineTo(size.width / 2, pointingUp ? 0 : size.height)
      ..lineTo(size.width, pointingUp ? size.height : 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CaretPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.pointingUp != pointingUp;
}
