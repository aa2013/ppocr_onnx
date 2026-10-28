import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ppocr_onnx/ppocr_onnx.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  test('asset worker and file engine retain results across reloads', () async {
    const directory = 'assets/models';
    final image = await rootBundle.load('integration_test/assets/sample_doc.png');
    final bytes = image.buffer.asUint8List(image.offsetInBytes, image.lengthInBytes);
    final worker = OcrWorker(modelPath: directory);
    addTearDown(worker.dispose);
    // ignore: avoid_print
    print('Starting worker');
    await Future.wait([worker.start(), worker.start()]);
    // ignore: avoid_print
    print('Worker loaded; running inference');
    final first = await worker.run(bytes);
    expect(first.lines, isNotEmpty);
    expect(first.diagnostics!.accurate, isFalse);
    // ignore: avoid_print
    print('Worker inference complete; restarting');
    await worker.dispose();
    final running = worker.run(bytes);
    final stopping = worker.dispose();
    final second = await running;
    await stopping;
    expect(second.fullText, first.fullText);
    expect(second.lines.first.polygon, first.lines.first.polygon);
    final temp = await Directory.systemTemp.createTemp('ppocr_test_');
    addTearDown(() => temp.delete(recursive: true));
    for (final name in ['ppocr_det.onnx', 'ppocr_rec.onnx', 'ppocr_dict.txt']) {
      final data = await rootBundle.load('$directory/$name');
      await File('${temp.path}/$name').writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    }
    final engine = OcrEngine(modelPath: temp.path);
    addTearDown(engine.dispose);
    await engine.load();
    final result = await engine.run(bytes);
    expect(result.fullText, first.fullText);
    await engine.dispose();
    await engine.load();
    final pending = engine.run(bytes);
    final closing = engine.dispose();
    expect((await pending).fullText, first.fullText);
    await closing;
    expect(engine.isReady, isFalse);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
