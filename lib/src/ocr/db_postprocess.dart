import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:clipper2/clipper2.dart';

import 'ocr_geometry.dart';

/// DB 文本检测后处理，严格对应 PaddleOCR 的 `DBPostProcess`。
///
/// 流程与官方保持一致：二值化 → 提取轮廓 → 求最小外接矩形 →
/// 多边形内概率均值打分 → 按 box_thresh 过滤 → unclip 外扩 →
/// 再求一次最小外接矩形 → 边长过滤。任一环节偏离官方实现都会
/// 导致框偏小或碎片化，进而让识别结果出现错字与断句。
class DbPostprocessor {
  DbPostprocessor._();

  /// 概率图二值化阈值，取自模型 inference.yml。
  static const double binaryThresh = 0.2;

  /// 多边形内平均概率阈值，取自模型 inference.yml。
  static const double boxThresh = 0.45;

  /// 文本框扩张系数，取自模型 inference.yml。
  static const double unclipRatio = 1.4;

  /// 单张图最多处理的候选轮廓数量，取自模型 inference.yml。
  static const int maxCandidates = 3000;

  /// 框的最小边长；官方对 unclip 前的框用该值，外扩后要求 +2。
  static const double minSize = 3;

  /// 解析概率图为带检测分数的文本框列表，坐标为原图坐标系。
  ///
  /// [prob] 为 [1, 1, height, width] 形状的扁平数据，[scaleX]/[scaleY] 用于
  /// 把检测输入网格坐标换算回原图坐标。[threshOverride] 供「敏感」分支
  /// 放宽二值化阈值使用。
  static List<DbBox> extractScoredBoxes(
    Float32List prob,
    int width,
    int height, {
    required double scaleX,
    required double scaleY,
    double? threshOverride,
  }) {
    final List<List<int>> contours =
        _findContours(prob, width, height, threshOverride ?? binaryThresh);
    final List<DbBox> boxes = <DbBox>[];

    for (final List<int> contour in contours.take(maxCandidates)) {
      // 官方 get_mini_boxes：先取最小外接矩形并据此判断边长。
      final _MiniBox miniBox = _miniBoxOf(contour, width);
      if (miniBox.shortSide < minSize) {
        continue;
      }

      // 官方 box_score_fast：用外接矩形四点多边形内的概率均值作为分数。
      final double score = _boxScoreFast(prob, width, height, miniBox.quad);
      if (score < boxThresh) {
        continue;
      }

      final List<ui.Offset>? inflated = _unclip(miniBox.quad);
      if (inflated == null) {
        continue;
      }
      // 官方对 unclip 后的框再求一次最小外接矩形，并使用 +2 的边长下限。
      final _MiniBox finalBox = _miniBoxOfOffsets(inflated);
      if (finalBox.shortSide < minSize + 2) {
        continue;
      }

      boxes.add(DbBox(
        polygon: <ui.Offset>[
          for (final ui.Offset p in finalBox.quad)
            ui.Offset(
              (p.dx * scaleX).clamp(0, double.infinity),
              (p.dy * scaleY).clamp(0, double.infinity),
            ),
        ],
        score: score,
      ));
    }

    return _sortReadingOrder(boxes);
  }

  /// 兼容只需要几何框的调用方，丢弃 DB 检测分数。
  static List<List<ui.Offset>> extractBoxes(
    Float32List prob,
    int width,
    int height, {
    required double scaleX,
    required double scaleY,
    double? threshOverride,
  }) {
    return extractScoredBoxes(
      prob,
      width,
      height,
      scaleX: scaleX,
      scaleY: scaleY,
      threshOverride: threshOverride,
    ).map((DbBox box) => box.polygon).toList();
  }

  /// 按官方 `unclip` 做多边形外扩。
  ///
  /// 距离为 `area * unclipRatio / perimeter`，连接方式用圆角（JT_ROUND），
  /// 官方实现同样使用圆角；圆角外扩在各方向上的扩张量一致。
  static List<ui.Offset>? _unclip(List<ui.Offset> quad) {
    final Path64 path = Path64Ext.from(<int>[
      for (final ui.Offset p in quad) ...<int>[p.dx.round(), p.dy.round()],
    ]);
    if (path.length < 3) {
      return null;
    }
    final double area = path.area.abs();
    final double perimeter = _perimeter(path);
    if (area <= 0 || perimeter <= 0) {
      return null;
    }
    final double distance = area * unclipRatio / perimeter;

    final ClipperOffset offset = ClipperOffset(miterLimit: 2.0);
    offset.addPath(path, joinType: JoinType.round, endType: EndType.polygon);
    final Paths64 inflated = offset.execute(delta: distance);
    if (inflated.isEmpty) {
      return null;
    }
    // 官方要求外扩后为单一闭环，否则丢弃。但 Clipper2 在细长条上做圆角
    // 外扩时可能产生退化片段，直接丢弃会让大量正常文本行凭空消失，
    // 因此这里取面积最大的片段，仅在明显退化时才判为失败。
    Path64 best = inflated.first;
    double bestArea = best.area.abs();
    for (final Path64 candidate in inflated.skip(1)) {
      final double candidateArea = candidate.area.abs();
      if (candidateArea > bestArea) {
        best = candidate;
        bestArea = candidateArea;
      }
    }
    if (best.length < 3 || bestArea <= 0) {
      return null;
    }
    return <ui.Offset>[
      for (final Point64 p in best) ui.Offset(p.x.toDouble(), p.y.toDouble()),
    ];
  }

  /// 官方 `box_score_fast`：多边形 mask 覆盖区域内的概率均值。
  ///
  /// 与「连通域像素均值」不同，这里按框的几何范围取样，框偏小或偏大
  /// 都会如实反映在分数上，从而使 box_thresh 过滤更准确。
  static double _boxScoreFast(
    Float32List prob,
    int width,
    int height,
    List<ui.Offset> quad,
  ) {
    double minX = quad.first.dx;
    double maxX = quad.first.dx;
    double minY = quad.first.dy;
    double maxY = quad.first.dy;
    for (final ui.Offset p in quad) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    final int x0 = minX.floor().clamp(0, width - 1);
    final int x1 = maxX.ceil().clamp(0, width - 1);
    final int y0 = minY.floor().clamp(0, height - 1);
    final int y1 = maxY.ceil().clamp(0, height - 1);

    double sum = 0;
    int count = 0;
    for (int y = y0; y <= y1; y++) {
      for (int x = x0; x <= x1; x++) {
        if (_pointInPolygon(x + 0.5, y + 0.5, quad)) {
          sum += prob[y * width + x];
          count++;
        }
      }
    }
    return count == 0 ? 0 : sum / count;
  }

  /// 射线法判断点是否落在多边形内，即检测打分所用掩码的覆盖范围。
  static bool _pointInPolygon(double px, double py, List<ui.Offset> poly) {
    bool inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final ui.Offset pi = poly[i];
      final ui.Offset pj = poly[j];
      final bool intersects = (pi.dy > py) != (pj.dy > py) &&
          px < (pj.dx - pi.dx) * (py - pi.dy) / (pj.dy - pi.dy) + pi.dx;
      if (intersects) {
        inside = !inside;
      }
    }
    return inside;
  }

  /// 由轮廓点构造最小外接矩形（官方 get_mini_boxes）。
  static _MiniBox _miniBoxOf(List<int> contour, int width) {
    return _miniBoxOfOffsets(<ui.Offset>[
      for (final int index in contour)
        ui.Offset((index % width) + 0.5, (index ~/ width) + 0.5),
    ]);
  }

  static _MiniBox _miniBoxOfOffsets(List<ui.Offset> points) {
    final List<ui.Offset> rect = OcrGeometry.minAreaRect(points);
    if (rect.length != 4) {
      return const _MiniBox(<ui.Offset>[], 0);
    }
    final List<ui.Offset> ordered = OcrGeometry.orderQuad(rect);
    final double shortSide = math.min(
      (ordered[1] - ordered[0]).distance,
      (ordered[3] - ordered[0]).distance,
    );
    return _MiniBox(ordered, shortSide);
  }

  /// 提取二值化后的连通区域。
  ///
  /// 先做一次 2×2 矩形核膨胀，把同一行相邻字的微弱响应连起来，避免一行被
  /// 切成多个碎片框；再按 8 邻域标记连通域，只保留每个连通域的**外轮廓
  /// 边缘点**。
  ///
  /// 用边缘点而非区域全部像素求最小外接矩形，几何结果一致，且大幅减少
  /// 计算量。
  static List<List<int>> _findContours(
    Float32List prob,
    int width,
    int height,
    double threshold,
  ) {
    final Uint8List mask = _dilate2x2(prob, width, height, threshold);
    final int total = width * height;
    // -1 表示尚未访问；用显式栈代替递归，避免大图下栈溢出。
    final Int32List labels = Int32List(total)..fillRange(0, total, -1);
    final List<List<int>> contours = <List<int>>[];
    final List<int> stack = <int>[];

    for (int start = 0; start < total; start++) {
      if (labels[start] != -1 || mask[start] == 0) {
        continue;
      }
      final List<int> boundary = <int>[];
      final int label = contours.length;
      stack
        ..clear()
        ..add(start);
      labels[start] = label;

      while (stack.isNotEmpty) {
        final int index = stack.removeLast();
        final int x = index % width;
        final int y = index ~/ width;
        bool isBoundary = x == 0 ||
            y == 0 ||
            x == width - 1 ||
            y == height - 1;
        for (int dy = -1; dy <= 1; dy++) {
          final int ny = y + dy;
          if (ny < 0 || ny >= height) {
            continue;
          }
          for (int dx = -1; dx <= 1; dx++) {
            final int nx = x + dx;
            if (nx < 0 || nx >= width) {
              continue;
            }
            final int neighbor = ny * width + nx;
            if (mask[neighbor] == 0) {
              isBoundary = true;
              continue;
            }
            if (labels[neighbor] != -1) {
              continue;
            }
            labels[neighbor] = label;
            stack.add(neighbor);
          }
        }
        if (isBoundary) {
          boundary.add(index);
        }
      }

      // 少于 3 个边缘点无法构成区域，与检测算法丢弃退化轮廓的做法一致。
      if (boundary.length >= 3) {
        contours.add(boundary);
      }
    }

    return contours;
  }

  /// 2×2 矩形核膨胀。
  ///
  /// 锚点取左上偏置，膨胀方向因此是「向右下扩张」。
  static Uint8List _dilate2x2(
    Float32List prob,
    int width,
    int height,
    double threshold,
  ) {
    final int total = width * height;
    final Uint8List src = Uint8List(total);
    for (int i = 0; i < total; i++) {
      src[i] = prob[i] > threshold ? 1 : 0;
    }
    final Uint8List out = Uint8List(total);
    for (int y = 0; y < height; y++) {
      final int row = y * width;
      for (int x = 0; x < width; x++) {
        if (src[row + x] == 0) {
          continue;
        }
        out[row + x] = 1;
        if (x + 1 < width) {
          out[row + x + 1] = 1;
        }
        if (y + 1 < height) {
          final int nextRow = row + width;
          out[nextRow + x] = 1;
          if (x + 1 < width) {
            out[nextRow + x + 1] = 1;
          }
        }
      }
    }
    return out;
  }

  static double _perimeter(Path64 path) {    if (path.length < 2) {
      return 0;
    }
    double sum = 0;
    for (int i = 0; i < path.length; i++) {
      final Point64 a = path[i];
      final Point64 b = path[(i + 1) % path.length];
      final double dx = (b.x - a.x).toDouble();
      final double dy = (b.y - a.y).toDouble();
      sum += math.sqrt(dx * dx + dy * dy);
    }
    return sum;
  }

  /// 按阅读顺序排序：先按纵坐标把框聚成若干行，行内再按 x 升序。
  ///
  /// 分两阶段而不是写成单个比较器，是因为「同一行内比 x、跨行比 y」的
  /// 混合比较不满足全序，会让 List.sort 结果不稳定。
  static List<DbBox> _sortReadingOrder(List<DbBox> boxes) {
    if (boxes.length < 2) {
      return boxes;
    }
    final List<DbBox> byTop = List<DbBox>.of(boxes)
      ..sort((DbBox a, DbBox b) => a.polygon[0].dy.compareTo(b.polygon[0].dy));

    final List<List<DbBox>> rows = <List<DbBox>>[];
    for (final DbBox box in byTop) {
      final List<ui.Offset> polygon = box.polygon;
      final double centerY = (polygon[0].dy + polygon[3].dy) / 2;
      final double boxH = math.max((polygon[3].dy - polygon[0].dy).abs(), 1);
      if (rows.isNotEmpty) {
        final List<ui.Offset> representative = rows.last.first.polygon;
        final double rowCenterY =
            (representative[0].dy + representative[3].dy) / 2;
        final double rowH =
            math.max((representative[3].dy - representative[0].dy).abs(), 1);
        if ((centerY - rowCenterY).abs() <= math.min(boxH, rowH) * 0.5) {
          rows.last.add(box);
          continue;
        }
      }
      rows.add(<DbBox>[box]);
    }

    final List<DbBox> sorted = <DbBox>[];
    for (final List<DbBox> row in rows) {
      row.sort((DbBox a, DbBox b) =>
          a.polygon[0].dx.compareTo(b.polygon[0].dx));
      sorted.addAll(row);
    }
    return sorted;
  }
}

/// DB 后处理输出的文本框及其概率均值分数。
class DbBox {
  const DbBox({required this.polygon, required this.score});

  final List<ui.Offset> polygon;
  final double score;
}

/// 最小外接矩形及其短边长度，对应官方 `get_mini_boxes` 的返回值。
class _MiniBox {
  const _MiniBox(this.quad, this.shortSide);

  /// 按左上、右上、右下、左下排序的四个顶点。
  final List<ui.Offset> quad;

  final double shortSide;
}
