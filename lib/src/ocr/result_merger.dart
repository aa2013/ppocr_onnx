import 'dart:math' as math;
import 'dart:ui' as ui;

import 'ocr_geometry.dart';
import 'perspective.dart';

/// 一个分支检出的候选文本框。
class BranchBox {
  const BranchBox({
    required this.polygon,
    required this.score,
    required this.branchIndex,
    required this.branchName,
  });

  /// 原图坐标系下的四个角点。
  final List<ui.Offset> polygon;

  /// 检测模型的概率均值分。
  final double score;

  /// 命中该框的分支在配置列表中的下标。
  final int branchIndex;

  final String branchName;

  ui.Rect get bounds => OcrGeometry.boundsOf(polygon);
}

/// 合并后的识别区域：同一片文字在所有分支上的框收敛成一个区域。
class MergedRegion {
  MergedRegion({
    required this.polygon,
    required this.branches,
    required this.score,
  });

  /// 识别窗（已含四周与行向外扩），原图坐标系。
  List<ui.Offset> polygon;

  /// 贡献过这个区域的分支配置下标。
  final Set<int> branches;

  /// 成员框的检测分数最大值。
  double score;

  ui.Rect get bounds => OcrGeometry.boundsOf(polygon);
}

/// 候选合并参数。
class MergeConfig {
  const MergeConfig({
    this.iouThreshold = 0.30,
    this.containThreshold = 0.75,
    this.stitchSameLine = true,
    this.lineMinYOverlap = 0.55,
    this.lineMaxGapRatio = 0.80,
    this.lineMaxHeightDiffRatio = 0.45,
    this.lineMaxWidthRatio = 6.0,
    this.regionPadRatio = 0.30,
    this.regionPadLongRatio = 1.2,
  });

  final double iouThreshold;
  final double containThreshold;
  final bool stitchSameLine;
  final double lineMinYOverlap;
  final double lineMaxGapRatio;
  final double lineMaxHeightDiffRatio;
  final double lineMaxWidthRatio;
  final double regionPadRatio;
  final double regionPadLongRatio;
}

/// 把多分支的检出框合并成识别区域。
class BoxMerger {
  BoxMerger._();

  /// 跨分支去重：重合度高或包含度高的框只保留一个，但记住全部贡献分支。
  ///
  /// 同一行文字在 raw、2x、3x 三个分支上都会被检出，直接全送识别会得到
  /// 三份重复结果；去重同时保留下所有分支下标，供后续「每个区域在哪些
  /// 图上各识别一次」使用。
  static List<MergedRegion> merge(
    List<BranchBox> boxes,
    MergeConfig config,
  ) {
    // 分数高的先占位，避免碎片框把完整框挤掉。
    final List<BranchBox> sorted = List<BranchBox>.of(boxes)
      ..sort((BranchBox a, BranchBox b) => b.score.compareTo(a.score));

    final List<MergedRegion> regions = <MergedRegion>[];
    for (final BranchBox box in sorted) {
      MergedRegion? host;
      for (final MergedRegion region in regions) {
        final double iou = polygonIoU(box.polygon, region.polygon);
        final double contain = containmentRatio(box.polygon, region.polygon);
        if (iou >= config.iouThreshold || contain >= config.containThreshold) {
          host = region;
          break;
        }
      }
      if (host == null) {
        regions.add(MergedRegion(
          polygon: List<ui.Offset>.of(box.polygon),
          branches: <int>{box.branchIndex},
          score: box.score,
        ));
        continue;
      }
      host.branches.add(box.branchIndex);
      host.score = math.max(host.score, box.score);
      // 同一行被切碎时，碎片框要并进整行：取两者的外包矩形能保住两侧的字。
      host.polygon = _unionPolygon(host.polygon, box.polygon);
    }
    return regions;
  }

  /// 同一行的碎片拼接：DB 对行首「一」「、」这类细笔画响应弱，常常整行
  /// 被检成「半行 + 一个孤字」。拼回整行再识别，模型才有完整上下文。
  static List<MergedRegion> stitchSameLine(
    List<MergedRegion> regions,
    MergeConfig config,
  ) {
    if (!config.stitchSameLine) {
      return regions;
    }
    final List<MergedRegion> out = List<MergedRegion>.of(regions);
    bool changed = true;
    while (changed) {
      changed = false;
      for (int i = 0; i < out.length && !changed; i++) {
        for (int j = i + 1; j < out.length; j++) {
          if (!_sameLine(out[i].bounds, out[j].bounds, config)) {
            continue;
          }
          final MergedRegion a = out[i];
          final MergedRegion b = out[j];
          final MergedRegion merged = MergedRegion(
            polygon: _unionPolygon(a.polygon, b.polygon),
            branches: <int>{...a.branches, ...b.branches},
            score: math.max(a.score, b.score),
          );
          out
            ..removeAt(j)
            ..[i] = merged;
          changed = true;
          break;
        }
      }
    }
    return out;
  }

  /// 构造识别窗：优先取最贴合字带的成员框，四周与行向外扩。
  ///
  /// 检测框紧贴笔画时，模型看不到字的上下沿与行首行尾，外扩能补回这部分
  /// 上下文；行向（长边方向）多给一截，是为了把 DB 漏掉的退字重新纳入。
  static List<ui.Offset> buildRecognitionWindow(
    MergedRegion region,
    MergeConfig config,
    int imageWidth,
    int imageHeight,
  ) {
    final ui.Rect r = region.bounds;
    final double shortSide = math.min(r.width, r.height);
    final double pad = shortSide * config.regionPadRatio;
    final double horizontal = r.width >= r.height
        ? shortSide * config.regionPadLongRatio
        : 0;
    final double vertical = r.height > r.width
        ? shortSide * config.regionPadLongRatio
        : 0;
    return padPolygon(
      region.polygon,
      pad,
      imageWidth,
      imageHeight,
      extraX: horizontal,
      extraY: vertical,
    );
  }

  /// 两个矩形的外包多边形，用于碎片拼接。
  static List<ui.Offset> _unionPolygon(
    List<ui.Offset> a,
    List<ui.Offset> b,
  ) {
    final ui.Rect merged = OcrGeometry.boundsOf(a).expandToInclude(
      OcrGeometry.boundsOf(b),
    );
    return <ui.Offset>[
      merged.topLeft,
      merged.topRight,
      merged.bottomRight,
      merged.bottomLeft,
    ];
  }

  /// 判断两个区域是否属于同一行且间隔够近。
  static bool _sameLine(ui.Rect a, ui.Rect b, MergeConfig config) {
    final double hA = math.max(a.height, 1);
    final double hB = math.max(b.height, 1);
    final double shortSide = math.min(hA, hB);
    final double longSide = math.max(hA, hB);
    if (shortSide / longSide < 1 - config.lineMaxHeightDiffRatio) {
      return false;
    }
    // 行内向：竖直重叠比例要够。
    final double overlap =
        math.min(a.bottom, b.bottom) - math.max(a.top, b.top);
    if (overlap / shortSide < config.lineMinYOverlap) {
      return false;
    }
    // 横向：间隙不能超过字高的若干倍。
    final double gap = math.max(a.left, b.left) - math.min(a.right, b.right);
    if (gap > shortSide * config.lineMaxGapRatio) {
      return false;
    }
    // 拼出来的行不能长到离谱，否则会把两段不相干的文字粘在一起。
    final double unionWidth =
        math.max(a.right, b.right) - math.min(a.left, b.left);
    return unionWidth <= shortSide * config.lineMaxWidthRatio;
  }
}

/// 候选识别结果及其打分，用于在一行文字的多个变体之间择优。
class RecognizeCandidate {
  const RecognizeCandidate({
    required this.text,
    required this.confidence,
    required this.label,
    required this.scale,
    required this.enhanced,
  });

  final String text;
  final double confidence;
  final String label;
  final double scale;
  final bool enhanced;
}

/// 择优打分。
///
/// 核心是「几何契合度」：区域长短边比给出这行文字**应当**有多少个 em，
/// 识别结果估算出的 em 数与之越接近，说明读全了；少读字或多读乱码都会
/// 让 fill 偏离 1。纯置信度不可靠 —— PP-OCR 的 CTC 置信度极易饱和，
/// 读错的行也常常给出 0.99。
double scoreVariant(
  RecognizeCandidate candidate,
  double regionLong,
  double regionShort,
) {
  const double rawCropBonus = 2.0;
  const double fillTolerance = 0.10;
  const double maxPenalty = 5.0;

  final double expectedEm = regionLong / math.max(1.0, regionShort);
  if (expectedEm <= 0.5) {
    // 区域近似一个点（竖排单字），退回「长度 × 置信度」。
    return candidate.text.length * math.max(candidate.confidence, 0.05);
  }
  final double actualEm = estimateTextWidthInEm(candidate.text);
  final double fill = actualEm / expectedEm;
  final double deviation = (fill - 1.0).abs();
  final double penalty = deviation <= fillTolerance
      ? 0.0
      : math.min(deviation - fillTolerance, maxPenalty);
  final double geometry = (5.0 - penalty) +
      0.05 * candidate.confidence +
      0.001 * candidate.text.length;
  // 原像素优先：二次二值化会偶发多吐/少吐字；平局时更高的放大倍数更可靠。
  return geometry +
      (candidate.enhanced ? 0.0 : rawCropBonus) +
      0.001 * candidate.scale;
}
