import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../ocr/ocr_result.dart';

/// 在图片上绘制 OCR 框，并把悬浮索引回传给结果列表。
class OcrOverlayViewer extends StatefulWidget {
  const OcrOverlayViewer({
    super.key,
    required this.image,
    required this.imageSize,
    required this.lines,
    this.hoveredIndex,
    this.onHovered,
    this.onSelected,
  });

  final ImageProvider image;
  final ui.Size imageSize;
  final List<OcrLine> lines;
  final int? hoveredIndex;
  final ValueChanged<int?>? onHovered;
  final ValueChanged<int?>? onSelected;

  @override
  State<OcrOverlayViewer> createState() => _OcrOverlayViewerState();
}

class _OcrOverlayViewerState extends State<OcrOverlayViewer> {
  int? _localHovered;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (PointerHoverEvent event) {
        final int? index = _hitTest(event.localPosition);
        if (index != _localHovered) {
          setState(() => _localHovered = index);
          widget.onHovered?.call(index);
        }
      },
      onExit: (_) {
        setState(() => _localHovered = null);
        widget.onHovered?.call(null);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (TapUpDetails details) {
          widget.onSelected?.call(_hitTest(details.localPosition));
        },
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image(image: widget.image, fit: BoxFit.contain),
            CustomPaint(
              painter: _OverlayPainter(
                imageSize: widget.imageSize,
                lines: widget.lines,
                hoveredIndex: widget.hoveredIndex ?? _localHovered,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 将局部坐标还原为原图坐标，使用实际多边形排除倾斜框外的空白。
  int? _hitTest(Offset point) {
    final Size? viewport = (context.findRenderObject() as RenderBox?)?.size;
    if (viewport == null || widget.imageSize.isEmpty) return null;
    final double scale = math.min(
      viewport.width / widget.imageSize.width,
      viewport.height / widget.imageSize.height,
    );
    final Offset origin = Offset(
      (viewport.width - widget.imageSize.width * scale) / 2,
      (viewport.height - widget.imageSize.height * scale) / 2,
    );
    final Offset imagePoint = (point - origin) / scale;
    for (int i = 0; i < widget.lines.length; i++) {
      final polygon = widget.lines[i].polygon;
      if (polygon.length < 3) continue;
      final path = Path()..addPolygon(polygon, true);
      if (path.contains(imagePoint)) return i;
    }
    return null;
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({
    required this.imageSize,
    required this.lines,
    required this.hoveredIndex,
  });

  final ui.Size imageSize;
  final List<OcrLine> lines;
  final int? hoveredIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.isEmpty || size.isEmpty) return;
    final FittedSizes fitted = applyBoxFit(BoxFit.contain, imageSize, size);
    final Rect destination = Alignment.center.inscribe(fitted.destination, Offset.zero & size);
    final double scale = destination.width / imageSize.width;
    for (int i = 0; i < lines.length; i++) {
        final OcrLine line = lines[i];
        final Path path = Path();
        for (int p = 0; p < line.polygon.length; p++) {
          final Offset point = destination.topLeft +
              Offset(line.polygon[p].dx * scale, line.polygon[p].dy * scale);
          if (p == 0) {
            path.moveTo(point.dx, point.dy);
          } else {
            path.lineTo(point.dx, point.dy);
          }
        }
        path.close();
      canvas.drawPath(path, Paint()
          ..color = i == hoveredIndex ? Colors.orange : Colors.red
          ..style = PaintingStyle.stroke
          ..strokeWidth = i == hoveredIndex ? 3 : 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter oldDelegate) =>
      oldDelegate.lines != lines ||
      oldDelegate.hoveredIndex != hoveredIndex || oldDelegate.imageSize != imageSize;
}
