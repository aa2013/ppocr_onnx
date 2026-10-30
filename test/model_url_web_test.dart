@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ppocr_onnx/src/ocr/model_paths.dart';
import 'package:ppocr_onnx/src/ocr/model_url.dart'
    if (dart.library.js_interop) 'package:ppocr_onnx/src/ocr/model_url_web.dart';

/// 浏览器中的 asset key 必须包含引擎附加的外层资源目录。
void main() {
  test('default model asset resolves to bundled web URL', () {
    const paths = OcrModelPaths.defaults();
    expect(resolveModelUrl(paths.det), 'assets/assets/models/ppocr_det.onnx');
    expect(resolveModelUrl(paths.rec), 'assets/assets/models/ppocr_rec.onnx');
  });

  test('trailing directory separator does not duplicate separators', () {
    const paths = OcrModelPaths('assets/models/');
    expect(resolveModelUrl(paths.det), 'assets/assets/models/ppocr_det.onnx');
  });

  test('package asset key keeps package namespace', () {
    expect(resolveModelUrl('packages/demo/models/det.onnx'),
      'assets/packages/demo/models/det.onnx');
  });
}
