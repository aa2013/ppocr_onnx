import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:ppocr_onnx/src/ocr/ctc_decoder.dart';
import 'package:ppocr_onnx/src/ocr/ocr_engine.dart';
import 'package:ppocr_onnx/src/ocr/branch_preprocessor.dart';
import 'package:ppocr_onnx/src/ocr/db_postprocess.dart';
import 'package:ppocr_onnx/src/ocr/image_preprocessor.dart';
import 'package:ppocr_onnx/src/ocr/result_merger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('快速模式仅用原图，高精度保留五分支', () {
    final engine = OcrEngine();
    expect(engine.branchesFor(OcrMode.fast).map((b) => b.kind),
        <OcrBranchKind>[OcrBranchKind.raw]);
    expect(engine.branchesFor(OcrMode.accurate), OcrBranch.surveillance);
    expect(engine.branchesFor(OcrMode.accurate), hasLength(5));
  });


  test('从指定路径读取字典字符', () async {
    final CtcDecoder decoder = await CtcDecoder.load(File('test/fixtures/dict.txt').absolute.path);
    // 独立夹具验证字典读取，不要求下载真实模型。
    expect(decoder.dictionarySize, 3);
  });

  test('检测输入按 BGR 归一化且尺寸对齐 32', () {
    final img.Image image = img.Image(width: 1000, height: 500);
    img.fill(image, color: img.ColorRgb8(0, 0, 255));
    final DetInput input = OcrPreprocessor.buildDetInput(image);

    expect(input.width % 32, 0);
    expect(input.height % 32, 0);
    expect(input.data.length, input.width * input.height * 3);
    // 纯蓝像素 (R=0,G=0,B=255)：BGR 首通道为 B，第二个通道为 G。
    final int plane = input.width * input.height;
    expect(input.data[0], closeTo((1 - 0.485) / 0.229, 0.01));
    expect(input.data[plane], closeTo((0 - 0.456) / 0.224, 0.01));
    expect(input.scaleX, closeTo(1000 / input.width, 1e-9));
    expect(input.scaleY, closeTo(500 / input.height, 1e-9));
  });

  test('DB 后处理从合成概率图提取并外扩文本框', () {
    const int width = 64;
    const int height = 64;
    final List<double> prob = List<double>.filled(width * height, 0);
    for (int y = 27; y < 37; y++) {
      for (int x = 17; x < 47; x++) {
        prob[y * width + x] = 1.0;
      }
    }

    final List<List<Offset>> boxes = DbPostprocessor.extractBoxes(
      Float32List.fromList(prob),
      width,
      height,
      scaleX: 1,
      scaleY: 1,
    );

    expect(boxes.length, 1);
    final List<Offset> box = boxes.first;
    expect(box.length, 4);

    final List<double> xs = box.map((Offset p) => p.dx).toList()..sort();
    final List<double> ys = box.map((Offset p) => p.dy).toList()..sort();
    // unclip 后应比原始 30x10 更大，中心保持在 (32, 32) 附近。
    expect(xs.last - xs.first, greaterThan(30));
    expect(ys.last - ys.first, greaterThan(10));
    expect((xs.first + xs.last) / 2, closeTo(32, 2));
    expect((ys.first + ys.last) / 2, closeTo(32, 2));
    expect(xs.first, greaterThanOrEqualTo(0));
    expect(ys.first, greaterThanOrEqualTo(0));
  });

  test('识别输入宽度按文本真实宽高比扩展，不压缩长文本', () {
    final img.Image image = img.Image(width: 400, height: 40);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));

    // 宽高比 40 的长文本，宽度应扩展到 48*40 的量级而非被压到 320。
    final List<Offset> quad = <Offset>[
      const Offset(0, 10),
      const Offset(400, 10),
      const Offset(400, 30),
      const Offset(0, 30),
    ];
    final int width = OcrPreprocessor.recOutputWidth(quad);
    expect(width, 960);

    final Float32List data = OcrPreprocessor.buildRecInput(image, quad);
    expect(data.length, 3 * 48 * width);
    // 白色像素归一化后落在 [-1,1] 的上界。
    expect(data[0], closeTo(1.0, 1e-6));
  });

  test('CTC 解码合并重复并丢弃空白', () {
    // 类别 0=blank，1='!'，2='"'；序列 blank,!,!,blank,",! 应解出 '!"!'。
    final CtcDecoder decoder = CtcDecoder(<String>['!', '"']);
    final Float32List probs = Float32List.fromList(<double>[
      0.9, 0.05, 0.05, // blank
      0.1, 0.8, 0.1, // !
      0.1, 0.8, 0.1, // ! 连续重复，应被合并
      0.9, 0.05, 0.05, // blank
      0.1, 0.05, 0.85, // "
      0.1, 0.8, 0.1, // !
    ]);
    final DecodedText decoded = decoder.decode(probs, 6, 3);
    expect(decoded.text, '!"!');
    expect(decoded.confidence, greaterThan(0.7));
  });

  test('直接读取插件数值视图与原 Float32 路径的 CTC 文字和置信度一致', () {
    final decoder = CtcDecoder(<String>['甲', '乙']);
    // 覆盖空白、连续重复、重复间空白、空格和最高值并列。
    const classes = 4;
    final original = Float32List.fromList(<double>[
      0.9, 0.02, 0.03, 0.05,
      0.1, 0.7, 0.1, 0.1,
      0.1, 0.7, 0.1, 0.1,
      0.9, 0.02, 0.03, 0.05,
      0.1, 0.7, 0.1, 0.1,
      0.1, 0.1, 0.1, 0.7,
      0.1, 0.1, 0.7, 0.1,
      0.0, 0.5, 0.5, 0.0,
    ]);
    // 插件返回 Float32 数值提升后的 Dart double；模拟相同的原始列表。
    final List<dynamic> raw = original.toList();
    final legacy = decoder.decode(Float32List.fromList(raw.cast<double>()),
        original.length ~/ classes, classes);
    final direct = decoder.decode(raw.cast<num>(), raw.length ~/ classes, classes);
    expect(direct.text, '甲甲 乙甲');
    expect(direct.text, legacy.text);
    expect(direct.confidence, legacy.confidence);
    expect(decoder.decode(<num>[], 0, classes).text, isEmpty);
  });

  test('结果合并按检测分数优先处理高质量框', () {
    final List<ui.Offset> low = <ui.Offset>[
      const ui.Offset(0, 0),
      const ui.Offset(20, 0),
      const ui.Offset(20, 10),
      const ui.Offset(0, 10),
    ];
    final List<ui.Offset> high = <ui.Offset>[
      const ui.Offset(1, 1),
      const ui.Offset(19, 1),
      const ui.Offset(19, 9),
      const ui.Offset(1, 9),
    ];

    final List<MergedRegion> regions = BoxMerger.merge(<BranchBox>[
      BranchBox(
        polygon: low,
        score: 0.51,
        branchIndex: 0,
        branchName: 'low',
      ),
      BranchBox(
        polygon: high,
        score: 0.96,
        branchIndex: 1,
        branchName: 'high',
      ),
    ], const MergeConfig());

    expect(regions, hasLength(1));
    expect(regions.single.score, closeTo(0.96, 1e-9));
    expect(regions.single.branches, containsAll(<int>[0, 1]));
  });
}
