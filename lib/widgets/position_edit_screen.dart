import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/generated/app_localizations.dart';
import '../models/client.dart';
import '../models/ts_state.dart';

/// The plane spans ±[planeExtent] meters on both axes; dragging clamps there.
const double planeExtent = 10.0;

/// At or above this logical window width, modals (the per-client volume
/// sheet and the position editor) present as centered dialogs instead of a
/// full-width bottom sheet / full-screen page.
const double kAdaptiveDialogMinWidth = 800.0;

/// Opens the 2D position editor for [client]: a centered dialog on wide
/// (desktop) windows, the full-screen page below [kAdaptiveDialogMinWidth].
/// Changes apply live while the pad is dragged (there is no result to pop):
/// every update goes straight through the connection notifier into the Rust
/// mixer.
Future<void> openPositionEditor(BuildContext context, TsClient client) {
  if (MediaQuery.sizeOf(context).width >= kAdaptiveDialogMinWidth) {
    return showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: const Color(0xFF12122A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        constraints: const BoxConstraints(maxWidth: 760),
        child: PositionEditor(client: client, asDialog: true),
      ),
    );
  }
  return Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => PositionEditScreen(client: client)));
}

/// Full-screen route wrapper around [PositionEditor] for narrow windows and
/// phones.
class PositionEditScreen extends StatelessWidget {
  const PositionEditScreen({super.key, required this.client});

  final TsClient client;

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    return Scaffold(
      // Transparent so the app-wide custom background shows through.
      appBar: AppBar(
        title: Text(
          al.positionTitle,
          style: const TextStyle(color: Colors.white, fontSize: 17),
        ),
        backgroundColor: const Color(0xFF16213E),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SafeArea(child: PositionEditor(client: client)),
    );
  }
}

/// Top-down plane editor: "me" is fixed at the center, the client's dot is
/// dragged around. +x = right, +y = forward (top of the pad). [asDialog]
/// packs title, heading and controls beside the pad for the desktop dialog;
/// otherwise they stack above/below it for the full-screen page.
class PositionEditor extends ConsumerStatefulWidget {
  const PositionEditor({
    super.key,
    required this.client,
    this.asDialog = false,
  });

  final TsClient client;
  final bool asDialog;

  @override
  ConsumerState<PositionEditor> createState() => _PositionEditorState();
}

class _PositionEditorState extends ConsumerState<PositionEditor> {
  double? _x; // meters, +x = right
  double? _y; // meters, +y = forward (top of the pad)

  @override
  void initState() {
    super.initState();
    _x = widget.client.positionX;
    _y = widget.client.positionY;
  }

  void _apply(double? x, double? y) {
    ref
        .read(tsConnectionProvider.notifier)
        .setClientPosition(widget.client.id, x, y);
    setState(() {
      _x = x;
      _y = y;
    });
  }

  /// Maps a pad-local touch point to plane meters (top = +y = forward).
  void _setFromLocal(Offset local, Size size) {
    final half = size.width / 2;
    final dx = ((local.dx - half) / half * planeExtent).clamp(
      -planeExtent,
      planeExtent,
    );
    final dy = ((half - local.dy) / half * planeExtent).clamp(
      -planeExtent,
      planeExtent,
    );
    _apply(dx, dy);
  }

  @override
  Widget build(BuildContext context) {
    final al = AppLocalizations.of(context);
    final positioned = _x != null && _y != null;
    if (!widget.asDialog) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildClientHeading(),
          const SizedBox(height: 16),
          _buildPlane(al.positionSelf),
          const SizedBox(height: 12),
          _buildControls(al, positioned),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Cap the pad so the title/heading above and the controls column
          // beside it stay inside the dialog even in short windows.
          final side = math.min(
            400.0,
            math.max(200.0, constraints.maxHeight - 100),
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    al.positionTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                    color: Colors.grey,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildClientHeading(),
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildPlane(al.positionSelf, side: side),
                  const SizedBox(width: 28),
                  Expanded(child: _buildControls(al, positioned)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildClientHeading() => Row(
    children: [
      Icon(
        widget.client.isTalking ? Icons.mic : Icons.person,
        color: widget.client.isTalking ? Colors.blue : Colors.grey,
        size: 20,
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          widget.client.nickname,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );

  /// [side] fixes the square pad's size (dialog layout); without it the pad
  /// fills the available width (page layout).
  Widget _buildPlane(String selfLabel, {double? side}) {
    final pad = LayoutBuilder(
      builder: (context, constraints) {
        final padSize = constraints.biggest;
        void place(Offset local) => _setFromLocal(local, padSize);
        return MouseRegion(
          cursor: SystemMouseCursors.precise,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => place(d.localPosition),
            onPanStart: (d) => place(d.localPosition),
            onPanUpdate: (d) => place(d.localPosition),
            child: CustomPaint(
              painter: _PlanePainter(
                x: _x,
                y: _y,
                clientLabel: widget.client.nickname,
                selfLabel: selfLabel,
              ),
            ),
          ),
        );
      },
    );
    if (side == null) return AspectRatio(aspectRatio: 1, child: pad);
    return SizedBox(width: side, height: side, child: pad);
  }

  Widget _buildControls(AppLocalizations al, bool positioned) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        positioned
            ? 'x: ${_x!.toStringAsFixed(1)} m,   y: ${_y!.toStringAsFixed(1)} m'
            : al.positionUnset,
        style: const TextStyle(color: Colors.grey, fontSize: 13),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: positioned ? () => _apply(null, null) : null,
        icon: const Icon(Icons.restart_alt, size: 18),
        label: Text(al.positionReset),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.grey,
          side: const BorderSide(color: Color(0xFF2A2A4A)),
        ),
      ),
      const SizedBox(height: 16),
      Text(
        al.positionHint,
        textAlign: TextAlign.start,
        style: const TextStyle(color: Colors.grey, fontSize: 13, height: 1.5),
      ),
    ],
  );
}

class _PlanePainter extends CustomPainter {
  _PlanePainter({
    required this.x,
    required this.y,
    required this.clientLabel,
    required this.selfLabel,
  });

  final double? x;
  final double? y;

  /// The positioned client's nickname (drawn next to their dot).
  final String clientLabel;

  /// Localized "Me" label under the center dot.
  final String selfLabel;

  static const _background = Color(0xFF12122A);
  static const _grid = Color(0xFF2A2A4A);
  static const _axis = Color(0xFF3D3D66);
  static const _self = Colors.blue;
  static const _client = Color(0xFF30C0C0);

  Offset _planeToPx(double x, double y, Size size) {
    final half = size.width / 2;
    return Offset(half + x / planeExtent * half, half - y / planeExtent * half);
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset center,
    Color color,
    double fontSize, {
    Offset offset = Offset.zero,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 160);
    tp.paint(canvas, center + offset - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      Paint()..color = _background,
    );

    // Grid every 2 m, axes through the center slightly brighter.
    final gridPaint = Paint()
      ..color = _grid
      ..strokeWidth = 1;
    const step = 2 / planeExtent; // fraction of the half-width per 2 m
    for (var i = 1; i < 10; i++) {
      final p = half * step * i;
      canvas.drawLine(Offset(p, 0), Offset(p, size.height), gridPaint);
      canvas.drawLine(
        Offset(size.width - p, 0),
        Offset(size.width - p, size.height),
        gridPaint,
      );
      canvas.drawLine(Offset(0, p), Offset(size.width, p), gridPaint);
      canvas.drawLine(
        Offset(0, size.height - p),
        Offset(size.width, size.height - p),
        gridPaint,
      );
    }
    final axisPaint = Paint()
      ..color = _axis
      ..strokeWidth = 1;
    canvas.drawLine(Offset(half, 0), Offset(half, size.height), axisPaint);
    canvas.drawLine(Offset(0, half), Offset(size.width, half), axisPaint);

    // "Me" at the center.
    final center = Offset(half, half);
    canvas.drawCircle(center, 14, Paint()..color = _self);
    _drawLabel(canvas, selfLabel, center + const Offset(0, 28), _self, 12);

    // The client's dot — hollow placeholder at the center when unpositioned.
    if (x != null && y != null) {
      final p = _planeToPx(x!, y!, size);
      canvas.drawCircle(p, 14, Paint()..color = _client);
      _drawLabel(canvas, clientLabel, p + const Offset(0, 28), _client, 12);
    } else {
      canvas.drawCircle(
        center,
        14,
        Paint()
          ..color = _grid
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_PlanePainter oldDelegate) =>
      oldDelegate.x != x || oldDelegate.y != y;
}
