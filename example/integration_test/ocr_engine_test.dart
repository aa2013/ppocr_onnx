import 'dart:typed_data';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;

import 'package:ppocr_onnx/src/ocr/ocr_engine.dart';
import 'package:ppocr_onnx/src/ocr/ocr_result.dart';
import 'package:ppocr_onnx/src/ocr/ocr_diagnostics.dart';

/// 端到端集成测试：真实加载两个 ONNX 模型，对合成文字图片执行完整流水线。
///
/// 需在 Windows 桌面上运行：`flutter test integration_test -d windows`。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('真实模型可加载并完成一次完整推理', () async {
    final OcrEngine engine = OcrEngine();
    addTearDown(engine.dispose);
    final int loadMillis = await engine.load();
    expect(engine.isReady, isTrue);
    // ignore: avoid_print
    print('[bench] model load = ${loadMillis}ms');

    // 用真实英文单词贴近模型训练分布，纯几何图形检测得分偏低会被阈值过滤。
    final img.Image canvas = img.Image(width: 900, height: 300);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.drawString(canvas, 'Hello OCR World 2026',
        font: img.arial48, x: 60, y: 120, color: img.ColorRgb8(0, 0, 0));
    final Uint8List bytes = Uint8List.fromList(img.encodePng(canvas));

    final OcrResult result = await engine.run(bytes, mode: OcrMode.accurate);
    // ignore: avoid_print
    print('[bench] detect = ${result.detectMillis}ms, '
        'recognize = ${result.recognizeMillis}ms, '
        'lines = ${result.lines.length}');
    for (final OcrLine line in result.lines) {
      // ignore: avoid_print
      print('[line] "${line.text}" '
          'conf=${line.confidence.toStringAsFixed(3)} '
          'bounds=${line.bounds}');
    }

    // 绘制内容与识别结果应一致，允许大小写与空格的细微差异。
    expect(result.lines, isNotEmpty);
    final String merged = result.lines.map((OcrLine l) => l.text).join(' ');
    expect(merged.toLowerCase(), contains('hello'));
    expect(merged.toLowerCase(), contains('ocr'));
    expect(merged, contains('2026'));

    // 在同一会话上比较模式，并验证坏图失败后可以继续调用。
    await expectLater(engine.run(Uint8List(0)), throwsA(anything));
    expect(await engine.load(), 0);
    final sample = await File('integration_test/assets/sample_doc.png').readAsBytes();
    for (final mode in OcrMode.values) {
      final watch = Stopwatch()..start();
      final pending = engine.run(sample, mode: mode);
      await expectLater(engine.run(sample), throwsStateError);
      final measured = await pending;
      // ignore: avoid_print
      print('[sample] ${mode.name}: total=${watch.elapsedMilliseconds}ms '
          'det=${measured.detectMillis}ms rec=${measured.recognizeMillis}ms '
          'text=${measured.fullText}');
      expect(measured.lines, isNotEmpty);
      checkDiagnostics(measured, mode);
      // 重复相同输入检查快照独立、文字和坐标不被计时改变。
      final repeated = await engine.run(sample, mode: mode);
      checkDiagnostics(repeated, mode);
      expect(repeated.fullText, measured.fullText);
      expect(repeated.lines.map((line) => line.polygon).toList(),
          measured.lines.map((line) => line.polygon).toList());
      expect(identical(repeated.diagnostics, measured.diagnostics), isFalse);

    }
    // 释放需要等待识别完成，关闭后的引擎不得再次加载。
    final pending = engine.run(bytes);
    final closing = engine.dispose();
    await pending;
    await closing;
    await engine.load();
    expect(engine.isReady, isTrue);

    // 坐标换算校验：文字绘制在 (60, 120)，字号 48，检测框应落在该区域附近。
    final OcrLine first = result.lines.first;
    expect(first.polygon.length, 4);
    expect(first.bounds.left, closeTo(60, 40));
    expect(first.bounds.top, closeTo(120, 30));
    expect(first.bounds.height, inInclusiveRange(30, 80));


  }, timeout: const Timeout(Duration(minutes: 5)));
}

/// 校验真实调用计数与原耗时栏一致，并输出全部步骤用于定位瓶颈。
void checkDiagnostics(OcrResult result, OcrMode mode) {
  final data = result.diagnostics!;
  expect(data.branchCount, mode == OcrMode.fast ? 1 : 5);
  expect(data.detection.inferenceCount, data.branchCount);
  expect(data.recognition.inferenceCount,
      data.regionCount * (mode == OcrMode.fast ? 1 : 3));
  expect(data.lineCount, result.lines.length);
  expect(data.detection.totalMicros ~/ Duration.microsecondsPerMillisecond,
      result.detectMillis);
  expect(data.recognition.totalMicros ~/ Duration.microsecondsPerMillisecond,
      result.recognizeMillis);
  for (final entry in <String, OcrStageTiming>{
    'det': data.detection, 'rec': data.recognition,
  }.entries) {
    final stage = entry.value;
    expect(stage.steps.values.fold<int>(0, (a, b) => a + b), stage.totalMicros);
    // ignore: avoid_print
    print('[details] ${mode.name} ${entry.key}: '
        'calls=${stage.inferenceCount} elements=${stage.outputElements} '
        'averageUs=${stage.averageInferenceMicros} maxUs=${stage.maxInferenceMicros} '
        '${stage.steps.map((key, value) => MapEntry(key.name, value))}');
  }
}
