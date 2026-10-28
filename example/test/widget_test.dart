import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ppocr_onnx/ppocr_onnx.dart';
import 'package:ppocr_onnx_example/main.dart';

void main() {
  testWidgets('example starts in fast mode and exposes copy actions', (tester) async {
    await tester.pumpWidget(const PpOcrExampleApp());
    expect(find.text('PP-OCR ONNX'), findsOneWidget);
    expect(find.byTooltip('Copy image path'), findsOneWidget);
    expect(find.byTooltip('Copy model path'), findsOneWidget);
    expect(tester.widget<SegmentedButton<OcrMode>>(find.byType(SegmentedButton<OcrMode>)).selected, {OcrMode.fast});
    await tester.tap(find.text('Accurate'));
    await tester.pump();
    expect(tester.widget<SegmentedButton<OcrMode>>(find.byType(SegmentedButton<OcrMode>)).selected, {OcrMode.accurate});
  });
}
