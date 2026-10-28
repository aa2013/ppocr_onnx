import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ppocr_onnx/src/ocr/ocr_diagnostics.dart';
import 'package:ppocr_onnx/src/widgets/ocr_timing_details.dart';

/// 构造微秒级诊断样本，用于验证比例、长列表和状态切换。
OcrDiagnostics sampleDiagnostics() {
  final detection = OcrTimingCollector()
    ..record(OcrStep.imageDecode, 10)
    ..record(OcrStep.inference, 20);
  final recognition = OcrTimingCollector()
    ..record(OcrStep.inference, 20)
    ..record(OcrStep.inference, 40)
    ..record(OcrStep.outputRead, 80);
  return OcrDiagnostics(
    accurate: false, width: 900, height: 300, branchCount: 1,
    regionCount: 2, lineCount: 2,
    detection: detection.finish(50),
    recognition: recognition.finish(200),
  );
}

void main() {
  test('多区域累计、次数、均值与最大值，快照不可变且不受后续记录影响', () {
    final collector = OcrTimingCollector()
      ..record(OcrStep.inference, 150)
      ..record(OcrStep.inference, 250)
      ..record(OcrStep.outputRead, 30)
      ..outputElements = 100;
    final snapshot = collector.finish(500);
    expect(snapshot.inferenceCount, 2);
    expect(snapshot.averageInferenceMicros, 200);
    expect(snapshot.maxInferenceMicros, 250);
    expect(snapshot.outputElements, 100);
    expect(snapshot.steps[OcrStep.other], 70);
    expect(snapshot.steps.values.reduce((a, b) => a + b), snapshot.totalMicros);
    collector.record(OcrStep.inference, 10);
    expect(snapshot.inferenceCount, 2);
    expect(snapshot.steps[OcrStep.inference], 400);
    expect(() => snapshot.steps[OcrStep.other] = 0, throwsUnsupportedError);
  });

  test('零区域与新实例不继承旧调用统计，嵌套计时超额直接报错', () {
    final previous = OcrTimingCollector()..record(OcrStep.inference, 10);
    expect(previous.finish(10).inferenceCount, 1);
    final empty = OcrTimingCollector().finish(0);
    expect(empty.inferenceCount, 0);
    expect(empty.averageInferenceMicros, 0);
    expect(empty.maxInferenceMicros, 0);
    expect(empty.outputElements, 0);
    expect(empty.steps[OcrStep.other], 0);
    expect(() => previous.finish(5), throwsStateError);
  });

  testWidgets('明细默认收起、可滚动，重新运行或失败清空后不保留旧内容',
      (tester) async {
    final data = sampleDiagnostics();
    // 保持同一 widget 身份，覆盖实际页面传入空快照的生命周期。
    Future<void> show(OcrDiagnostics? value) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(
        children: <Widget>[OcrTimingDetails(diagnostics: value)],
      ))));
    }
    await show(null);
    expect(find.text('Available after recognition'), findsOneWidget);
    await show(data);
    expect(find.textContaining('Recognition inference'), findsNothing);
    await tester.tap(find.text('Timing details'));
    await tester.pump();
    expect(find.textContaining('Recognition inference'), findsOneWidget);
    final scroll = find.byKey(const ValueKey<String>('ocr-timing-scroll'));
    expect(tester.getSize(scroll).height, lessThanOrEqualTo(260));
    await tester.drag(scroll, const Offset(0, -600));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Timing details'));
    await tester.pump();
    expect(scroll, findsNothing);
    await tester.tap(find.text('Timing details'));
    await tester.pump();
    await show(null);
    expect(find.text('Available after recognition'), findsOneWidget);
    expect(find.textContaining('Recognition inference'), findsNothing);
    await show(sampleDiagnostics());
    expect(scroll, findsNothing);
  });
}
