import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ppocr_onnx/ppocr_onnx.dart';
import 'package:ppocr_onnx/src/ocr/ctc_decoder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('all fixed filenames resolve with trailing directory separator', () {
    const paths = OcrModelPaths('assets/models/');
    expect(paths.det, 'assets/models/ppocr_det.onnx');
    expect(paths.rec, 'assets/models/ppocr_rec.onnx');
    expect(paths.dict, 'assets/models/ppocr_dict.txt');
  });
  test('each missing file is reported before ONNX initialization', () async {
    final temp = await Directory.systemTemp.createTemp('ocr_missing_');
    addTearDown(() => temp.delete(recursive: true));
    final engine = OcrEngine(modelPath: temp.path);
    addTearDown(engine.dispose);
    for (final name in ['ppocr_det.onnx', 'ppocr_rec.onnx', 'ppocr_dict.txt']) {
      await expectLater(engine.load(), throwsA(predicate((error) => error.toString().contains(name))));
      expect(engine.isReady, isFalse);
      await File('${temp.path}/$name').writeAsString('placeholder');
    }
  });
  test('dictionary reload reads changed contents without cached strings', () async {
    final temp = await Directory.systemTemp.createTemp('ocr_dictionary_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/ppocr_dict.txt');
    await file.writeAsString('a\nb\n');
    expect((await CtcDecoder.load(file.path)).dictionarySize, 2);
    await file.writeAsString('x\n');
    expect((await CtcDecoder.load(file.path)).dictionarySize, 1);
    await file.writeAsString('');
    await expectLater(CtcDecoder.load(file.path), throwsStateError);
  });
  test('failed load can be retried after repeated dispose', () async {
    final engine = OcrEngine(modelPath: 'missing_model_assets');
    await engine.dispose();
    await engine.dispose();
    await expectLater(engine.load(), throwsA(predicate((error) => error.toString().contains('ppocr_det.onnx'))));
    await engine.dispose();
  });
}
