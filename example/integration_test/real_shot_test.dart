import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:image/image.dart' as img;

import 'package:ppocr_onnx/src/ocr/ocr_engine.dart';
import 'package:ppocr_onnx/src/ocr/ocr_result.dart';

/// 用真实截图验证识别质量，并输出每个文本行便于人工核对。
///
/// 图片随项目一起提交（integration_test/assets），换机器后无需外部文件即可
/// 复跑。flutter test 的工作目录是包根目录，因此用相对路径直接读文件。
void main() {
  const String samplePath = 'integration_test/assets/sample_doc.png';

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('真实截图识别', () async {
    final File file = File(samplePath);
    expect(
      file.existsSync(),
      isTrue,
      reason: '样例图片缺失：${File(samplePath).absolute.path}',
    );

    final Uint8List bytes = file.readAsBytesSync();
    final img.Image info = img.decodeImage(bytes)!;
    final OcrEngine engine = OcrEngine();
    await engine.load();
    final OcrResult result = await engine.run(bytes);

    // ignore: avoid_print
    print('===== ${file.uri.pathSegments.last} '
        '(${info.width}x${info.height}) lines=${result.lines.length} =====');
    for (final OcrLine line in result.lines) {
      // ignore: avoid_print
      print('${(line.confidence * 100).toStringAsFixed(0).padLeft(3)}% '
          '${line.text}');
    }

    // 该截图是密集技术文档，应能完整读出正文。
    expect(result.lines.length, greaterThan(10));
    expect(result.fullText, contains('时间戳'));
    expect(result.fullText, contains('SHA256'));
    expect(result.fullText, contains('MMDDHHMMSS'));

    await engine.dispose();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
