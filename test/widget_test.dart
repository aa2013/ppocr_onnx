import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ppocr_onnx/ppocr_onnx.dart';

void main() {
  testWidgets('hover and tap use the contained image transform', (tester) async {
    int? hovered;
    int? selected;
    const line = OcrLine(text: 'Hello', confidence: 0.9, polygon: [
      ui.Offset(0, 0), ui.Offset(100, 0), ui.Offset(100, 40), ui.Offset(0, 40),
    ]);
    await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(
      width: 200,
      height: 200,
      child: OcrOverlayViewer(
        image: MemoryImage(Uint8List.fromList(img.encodePng(img.Image(width: 200, height: 100)))),
        imageSize: const ui.Size(200, 100),
        lines: const [line],
        onHovered: (index) => hovered = index,
        onSelected: (index) => selected = index,
      ),
    ))));
    final origin = tester.getTopLeft(find.byType(OcrOverlayViewer));
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: origin);
    await mouse.moveTo(origin + const Offset(50, 70));
    await tester.pump();
    expect(hovered, 0);
    await tester.tapAt(origin + const Offset(50, 70));
    expect(selected, 0);
    await mouse.moveTo(origin + const Offset(50, 20));
    await tester.pump();
    expect(hovered, isNull);
    await mouse.removePointer();
  });
}
