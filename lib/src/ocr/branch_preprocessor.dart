import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// 检测分支的图像预处理。
///
/// 每个分支产出一张「同一场景的另一种看法」：放大分支补笔画细节，二值化
/// 分支把压背景的字洗成黑字白底，CLAHE 分支拉开局部对比度。单一路径在
/// 复杂版式上必然有漏检，多路互补才能把字找全。
enum OcrBranchKind {
  raw,
  upscale2x,
  upscale3x,
  clahe,
  sharpen,
  adaptiveBin,
  otsuBin,
}

/// 一个检测分支的完整配置。
class OcrBranch {
  const OcrBranch({
    required this.kind,
    required this.name,
    this.enhance = OcrEnhance.none,
    this.binarize = false,
    this.useForRecognition = true,
    this.detThreshOverride,
  });

  final OcrBranchKind kind;

  /// 分支名，用于日志与择优记录。
  final String name;

  final OcrEnhance enhance;

  /// 该分支经过二值化，只用于找框；它的像素丢失了自然灰度分布，不能喂识别器。
  final bool binarize;

  /// 该分支的图像是否可用作识别候选图。
  final bool useForRecognition;

  /// 检测二值化阈值的覆盖值（null 表示用全局默认）。
  final double? detThreshOverride;

  /// 召回优先的分支组合：放大补小字、增强补低对比度，多路互补。
  static const List<OcrBranch> surveillance = <OcrBranch>[
    OcrBranch(kind: OcrBranchKind.raw, name: 'raw'),
    OcrBranch(
      kind: OcrBranchKind.upscale2x,
      name: 'upscale2x',
    ),
    OcrBranch(
      kind: OcrBranchKind.upscale3x,
      name: 'upscale3x',
    ),
    OcrBranch(
      kind: OcrBranchKind.clahe,
      name: 'clahe',
      enhance: OcrEnhance.clahe,
    ),
    OcrBranch(
      kind: OcrBranchKind.sharpen,
      name: 'sharpen',
      enhance: OcrEnhance.sharpen,
    ),
  ];
}

/// 单张图的增强模式。
enum OcrEnhance { none, clahe, sharpen }

/// 分支预处理：把原图变换成分支图，并返回该图相对原图的缩放倍数。
class BranchPreprocessor {
  BranchPreprocessor._();

  /// CLAHE 对比度上限：放大倍数过高会把纸面噪点也拉成笔画。
  static const double claheClipLimit = 3.0;

  /// CLAHE 网格边长：8×8 分块足以跟随局部光照变化，又不会把字内灰度拉开。
  static const int claheGridSize = 8;

  /// 锐化强度。
  static const double sharpenAmount = 1.0;

  /// 自适应二值化的邻域边长：一行字约 16~20px 高，31 能覆盖一个字的上下
  /// 左右而不跨到相邻行。
  static const int adaptiveBlockSize = 31;

  static const double adaptiveC = 10.0;

  static img.Image apply(img.Image source, OcrBranch branch) {
    img.Image out = source;
    switch (branch.kind) {
      case OcrBranchKind.upscale2x:
        out = _scale(source, 2);
      case OcrBranchKind.upscale3x:
        out = _scale(source, 3);
      case OcrBranchKind.adaptiveBin:
        out = _adaptiveBinary(source);
      case OcrBranchKind.otsuBin:
        out = _otsuBinary(source);
      case OcrBranchKind.clahe:
        out = _clahe(source);
      case OcrBranchKind.sharpen:
        out = _sharpen(source);
      case OcrBranchKind.raw:
        out = source;
    }
    switch (branch.enhance) {
      case OcrEnhance.clahe:
        out = _clahe(out);
      case OcrEnhance.sharpen:
        out = _sharpen(out);
      case OcrEnhance.none:
        break;
    }
    return out;
  }

  /// 分支相对原图的缩放倍数，用于把框坐标在分支图与原图之间换算。
  static double scaleOf(OcrBranch branch) => switch (branch.kind) {
        OcrBranchKind.upscale2x => 2.0,
        OcrBranchKind.upscale3x => 3.0,
        _ => 1.0,
      };

  /// 放大：用双三次插值，放大时比双线性更能保住笔画边缘。
  static img.Image _scale(img.Image source, int factor) {
    return img.copyResize(
      source,
      width: source.width * factor,
      height: source.height * factor,
      interpolation: img.Interpolation.cubic,
    );
  }

  /// 自适应高斯二值化并反色，让文字变成黑字白底。
  static img.Image _adaptiveBinary(img.Image source) {
    final int w = source.width;
    final int h = source.height;
    final List<int> gray = List<int>.filled(w * h, 0);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final img.Pixel p = source.getPixel(x, y);
        gray[y * w + x] = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
      }
    }
    // 高斯模糊近似局部均值：先做一次可分离盒式模糊再比较。
    final List<int> local = _boxBlurGray(gray, w, h, adaptiveBlockSize);
    final img.Image out = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int i = y * w + x;
        // 反色：像素比局部均值暗 → 判为文字 → 输出黑。
        final int v = gray[i] < local[i] - adaptiveC ? 0 : 255;
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return out;
  }

  /// Otsu 全局阈值二值化并反色。
  static img.Image _otsuBinary(img.Image source) {
    final int w = source.width;
    final int h = source.height;
    final List<int> gray = List<int>.filled(w * h, 0);
    final List<int> histogram = List<int>.filled(256, 0);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final img.Pixel p = source.getPixel(x, y);
        final int g = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
        gray[y * w + x] = g;
        histogram[g]++;
      }
    }
    final int threshold = _otsuThreshold(histogram, w * h);
    final img.Image out = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final int v = gray[y * w + x] < threshold ? 0 : 255;
        out.setPixelRgb(x, y, v, v, v);
      }
    }
    return out;
  }

  /// 由灰度直方图求 Otsu 阈值。
  static int _otsuThreshold(List<int> histogram, int total) {
    double sum = 0;
    for (int i = 0; i < 256; i++) {
      sum += i * histogram[i];
    }
    double sumB = 0;
    int weightB = 0;
    double best = -1;
    int threshold = 128;
    for (int t = 0; t < 256; t++) {
      weightB += histogram[t];
      if (weightB == 0) continue;
      final int weightF = total - weightB;
      if (weightF == 0) break;
      sumB += t * histogram[t];
      final double meanB = sumB / weightB;
      final double meanF = (sum - sumB) / weightF;
      final double between = weightB * weightF * (meanB - meanF) * (meanB - meanF);
      if (between > best) {
        best = between;
        threshold = t;
      }
    }
    return threshold;
  }

  /// 可分离盒式模糊，近似自适应阈值所需的局部均值窗口。
  static List<int> _boxBlurGray(List<int> gray, int w, int h, int radius) {
    final int r = math.max(1, radius ~/ 2);
    final List<int> horizontal = List<int>.filled(w * h, 0);
    for (int y = 0; y < h; y++) {
      int acc = 0;
      int count = 0;
      for (int x = -r; x < w; x++) {
        final int addX = x + r;
        if (addX >= 0 && addX < w) {
          acc += gray[y * w + addX];
          count++;
        }
        final int dropX = x - r - 1;
        if (dropX >= 0 && dropX < w) {
          acc -= gray[y * w + dropX];
          count--;
        }
        if (x >= 0) {
          horizontal[y * w + x] = count == 0 ? 0 : acc ~/ count;
        }
      }
    }
    final List<int> out = List<int>.filled(w * h, 0);
    for (int x = 0; x < w; x++) {
      int acc = 0;
      int count = 0;
      for (int y = -r; y < h; y++) {
        final int addY = y + r;
        if (addY >= 0 && addY < h) {
          acc += horizontal[addY * w + x];
          count++;
        }
        final int dropY = y - r - 1;
        if (dropY >= 0 && dropY < h) {
          acc -= horizontal[dropY * w + x];
          count--;
        }
        if (y >= 0) {
          out[y * w + x] = count == 0 ? 0 : acc ~/ count;
        }
      }
    }
    return out;
  }

  /// CLAHE：分块直方图均衡后做双线性插值，拉开局部对比度。
  static img.Image _clahe(img.Image source) {
    final int w = source.width;
    final int h = source.height;
    final int gx = math.min(claheGridSize, math.max(1, w));
    final int gy = math.min(claheGridSize, math.max(1, h));
    final int tileW = math.max(1, w ~/ gx);
    final int tileH = math.max(1, h ~/ gy);

    final List<List<int>> maps = <List<int>>[];
    for (int ty = 0; ty < gy; ty++) {
      for (int tx = 0; tx < gx; tx++) {
        final int x0 = tx * tileW;
        final int y0 = ty * tileH;
        final int x1 = tx == gx - 1 ? w : x0 + tileW;
        final int y1 = ty == gy - 1 ? h : y0 + tileH;
        maps.add(_tileMapping(source, x0, y0, x1, y1, math.max(1, (x1 - x0) * (y1 - y0))));
      }
    }

    final img.Image out = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final img.Pixel p = source.getPixel(x, y);
        final int r = _claheChannel(maps, gx, gy, tileW, tileH, w, h, x, y, p.r.toInt());
        final int g = _claheChannel(maps, gx, gy, tileW, tileH, w, h, x, y, p.g.toInt());
        final int b = _claheChannel(maps, gx, gy, tileW, tileH, w, h, x, y, p.b.toInt());
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  /// 单个分块的重映射表，clip limit 限制直方图峰值避免噪声被放大。
  static List<int> _tileMapping(
    img.Image source,
    int x0,
    int y0,
    int x1,
    int y1,
    int pixelCount,
  ) {
    final List<int> histogram = List<int>.filled(256, 0);
    for (int y = y0; y < y1; y++) {
      for (int x = x0; x < x1; x++) {
        final img.Pixel p = source.getPixel(x, y);
        histogram[(0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255)]++;
      }
    }
    final int limit = math.max(1, (claheClipLimit * pixelCount / 256).round());
    int excess = 0;
    for (int i = 0; i < 256; i++) {
      if (histogram[i] > limit) {
        excess += histogram[i] - limit;
        histogram[i] = limit;
      }
    }
    final int perBin = excess ~/ 256;
    int remainder = excess - perBin * 256;
    for (int i = 0; i < 256; i++) {
      histogram[i] += perBin;
      if (remainder > 0) {
        histogram[i]++;
        remainder--;
      }
    }
    final List<int> map = List<int>.filled(256, 0);
    int cdf = 0;
    for (int i = 0; i < 256; i++) {
      cdf += histogram[i];
      map[i] = ((cdf / pixelCount) * 255).round().clamp(0, 255);
    }
    return map;
  }

  /// 在分块边界之间做双线性插值，消除块状伪影。
  static int _claheChannel(
    List<List<int>> maps,
    int gx,
    int gy,
    int tileW,
    int tileH,
    int w,
    int h,
    int x,
    int y,
    int value,
  ) {
    final double fx = x / tileW - 0.5;
    final double fy = y / tileH - 0.5;
    final int x0 = fx.floor().clamp(0, gx - 1);
    final int y0 = fy.floor().clamp(0, gy - 1);
    final int x1 = (x0 + 1).clamp(0, gx - 1);
    final int y1 = (y0 + 1).clamp(0, gy - 1);
    final double wx = (fx - x0).clamp(0.0, 1.0);
    final double wy = (fy - y0).clamp(0.0, 1.0);
    final int v = value.clamp(0, 255);
    final double top = maps[y0 * gx + x0][v] * (1 - wx) + maps[y0 * gx + x1][v] * wx;
    final double bottom = maps[y1 * gx + x0][v] * (1 - wx) + maps[y1 * gx + x1][v] * wx;
    return (top * (1 - wy) + bottom * wy).round().clamp(0, 255);
  }

  /// 非锐化掩膜：原图 + amount ×（原图 - 模糊图）。
  static img.Image _sharpen(img.Image source) {
    final int w = source.width;
    final int h = source.height;
    final img.Image blurred = img.gaussianBlur(
      img.Image.from(source),
      radius: 1,
    );
    final img.Image out = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final img.Pixel p = source.getPixel(x, y);
        final img.Pixel q = blurred.getPixel(x, y);
        int sharp(num a, num b) =>
            (a + sharpenAmount * (a - b)).round().clamp(0, 255);
        out.setPixelRgb(x, y, sharp(p.r, q.r), sharp(p.g, q.g), sharp(p.b, q.b));
      }
    }
    return out;
  }
}
