import 'dart:ui' as ui;

import 'ocr_geometry.dart';
import 'ocr_diagnostics.dart';

/// 单个文本行的 OCR 识别结果。
class OcrLine {
  const OcrLine({
    required this.text,
    required this.confidence,
    required this.polygon,
  });

  /// 识别出的文字内容。
  final String text;

  /// 该文本框内所有非 blank 字符最高概率的平均值，范围 0~1。
  final double confidence;

  /// 文本区域在原图坐标系下的四个角点，顺序为左上、右上、右下、左下。
  final List<ui.Offset> polygon;

  /// 四个角点的轴对齐外接矩形。
  ui.Rect get bounds => OcrGeometry.boundsOf(polygon);
}

/// 一次完整 OCR 流程的结果与各阶段耗时。
class OcrResult {
  const OcrResult({
    required this.lines,
    required this.detectMillis,
    required this.recognizeMillis,
    this.diagnostics,
  });

  /// 可选的分步骤快照，旧调用方无需提供。
  final OcrDiagnostics? diagnostics;

  /// 按阅读顺序排列的文本行。
  final List<OcrLine> lines;

  /// 文本检测耗时（毫秒），含检测输入预处理。
  final int detectMillis;

  /// 全部文本行的识别总耗时（毫秒）。
  final int recognizeMillis;

  /// 检测与识别合计耗时（毫秒），不含模型加载。
  int get totalMillis => detectMillis + recognizeMillis;

  /// 按行拼接的完整文本，便于整段复制。
  String get fullText => lines.map((OcrLine line) => line.text).join('\n');
}
