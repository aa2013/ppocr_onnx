import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import 'ocr_geometry.dart';

/// 四边形到矩形的透视变换。
///
/// 文本检测输出的框常有轻微倾斜，必须用透视变换才能把梯形区域正确还原成
/// 水平矩形；双线性映射会在此基础上产生几何畸变，把字横向拉歪，识别模型
/// 据此读错。
class PerspectiveWarp {
  PerspectiveWarp._(Float64List inverse)
      : _m0 = inverse[0],
        _m1 = inverse[1],
        _m2 = inverse[2],
        _m3 = inverse[3],
        _m4 = inverse[4],
        _m5 = inverse[5],
        _m6 = inverse[6],
        _m7 = inverse[7],
        _m8 = inverse[8];

  final double _m0, _m1, _m2, _m3, _m4, _m5, _m6, _m7, _m8;

  /// 构造把 [quad]（左上、右上、右下、左下）映射到 [width]×[height] 矩形的变换。
  ///
  /// 目标矩形的角点取 `(0,0)`、`(width-1,0)`、`(width-1,height-1)`、
  /// `(0,height-1)`：用「像素索引」而非「像素边界」作角点，源图边缘的像素
  /// 才能落到目标图的首末列/行，不产生整体半像素偏移。
  static PerspectiveWarp? forQuad(
    List<ui.Offset> quad,
    int width,
    int height,
  ) {
    if (quad.length != 4 || width <= 0 || height <= 0) {
      return null;
    }
    final Float64List forward = _solveTransform(
      quad,
      <ui.Offset>[
        ui.Offset.zero,
        ui.Offset(width - 1.0, 0),
        ui.Offset(width - 1.0, height - 1.0),
        ui.Offset(0, height - 1.0),
      ],
    );
    final Float64List? inverse = _invert3x3(forward);
    return inverse == null ? null : PerspectiveWarp._(inverse);
  }

  ui.Offset sourceAt(double x, double y) {
    final double w = _m6 * x + _m7 * y + _m8;
    if (w.abs() < 1e-12) {
      return ui.Offset.zero;
    }
    return ui.Offset(
      (_m0 * x + _m1 * y + _m2) / w,
      (_m3 * x + _m4 * y + _m5) / w,
    );
  }

  /// 解 4 点对 4 点的透视变换矩阵（行优先 3×3）。
  ///
  /// 固定 `h22 = 1` 消去齐次尺度自由度，剩下的 8 个未知量由四组对应点
  /// 构成的线性方程组唯一确定。
  static Float64List _solveTransform(List<ui.Offset> src, List<ui.Offset> dst) {
    // 8 个未知量：h00 h01 h02 h10 h11 h12 h20 h21，h22 固定为 1。
    final List<Float64List> rows = <Float64List>[];
    final Float64List rhs = Float64List(8);
    for (int i = 0; i < 4; i++) {
      final double x = src[i].dx;
      final double y = src[i].dy;
      final double u = dst[i].dx;
      final double v = dst[i].dy;
      rows.add(Float64List.fromList(<double>[x, y, 1, 0, 0, 0, -u * x, -u * y]));
      rhs[i * 2] = u;
      rows.add(Float64List.fromList(<double>[0, 0, 0, x, y, 1, -v * x, -v * y]));
      rhs[i * 2 + 1] = v;
    }
    final Float64List? solved = _gauss(rows, rhs);
    if (solved == null) {
      return Float64List.fromList(<double>[1, 0, 0, 0, 1, 0, 0, 0, 1]);
    }
    return Float64List.fromList(<double>[
      solved[0], solved[1], solved[2],
      solved[3], solved[4], solved[5],
      solved[6], solved[7], 1.0,
    ]);
  }

  /// 高斯消元（带部分主元）解 8 元方程组。
  static Float64List? _gauss(List<Float64List> a, Float64List b) {
    const int n = 8;
    final List<Float64List> m = <Float64List>[
      for (int i = 0; i < n; i++) Float64List.fromList(<double>[...a[i], b[i]]),
    ];
    for (int col = 0; col < n; col++) {
      int pivot = col;
      for (int r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[pivot][col].abs()) {
          pivot = r;
        }
      }
      if (m[pivot][col].abs() < 1e-12) {
        return null;
      }
      if (pivot != col) {
        final Float64List tmp = m[pivot];
        m[pivot] = m[col];
        m[col] = tmp;
      }
      final double d = m[col][col];
      for (int c = col; c <= n; c++) {
        m[col][c] /= d;
      }
      for (int r = 0; r < n; r++) {
        if (r == col) continue;
        final double f = m[r][col];
        if (f == 0) continue;
        for (int c = col; c <= n; c++) {
          m[r][c] -= f * m[col][c];
        }
      }
    }
    return Float64List.fromList(<double>[for (int i = 0; i < n; i++) m[i][n]]);
  }

  /// 求 3×3 矩阵的逆。
  static Float64List? _invert3x3(Float64List m) {
    final double a = m[0], b = m[1], c = m[2];
    final double d = m[3], e = m[4], f = m[5];
    final double g = m[6], h = m[7], i = m[8];
    final double det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    if (det.abs() < 1e-12) {
      return null;
    }
    final double inv = 1.0 / det;
    return Float64List.fromList(<double>[
      (e * i - f * h) * inv,
      (c * h - b * i) * inv,
      (b * f - c * e) * inv,
      (f * g - d * i) * inv,
      (a * i - c * g) * inv,
      (c * d - a * f) * inv,
      (d * h - e * g) * inv,
      (b * g - a * h) * inv,
      (a * e - b * d) * inv,
    ]);
  }
}

/// 把四点整理为「左上、右上、右下、左下」。
///
/// 策略是「先按 y 取上下两组、再在组内按 x」。相比按质心角度排序，这个做法
/// 在细长文本框上更稳：质心角度排序在框极度扁平、上下顶点 y 相近时会因
/// 浮点抖动而换序，导致裁剪出的图上下翻转。
List<ui.Offset> orderQuadByYThenX(List<ui.Offset> pts) {
  if (pts.length != 4) {
    return List<ui.Offset>.of(pts);
  }
  final List<ui.Offset> sorted = List<ui.Offset>.of(pts)
    ..sort((ui.Offset a, ui.Offset b) {
      if (a.dy != b.dy) return a.dy.compareTo(b.dy);
      return a.dx.compareTo(b.dx);
    });
  final ui.Offset tl = sorted[0].dx <= sorted[1].dx ? sorted[0] : sorted[1];
  final ui.Offset tr = sorted[0].dx <= sorted[1].dx ? sorted[1] : sorted[0];
  final ui.Offset bl = sorted[2].dx <= sorted[3].dx ? sorted[2] : sorted[3];
  final ui.Offset br = sorted[2].dx <= sorted[3].dx ? sorted[3] : sorted[2];
  return <ui.Offset>[tl, tr, br, bl];
}

/// 计算裁剪尺寸：宽取上下两边长较大者，高取左右两边长较大者。
///
/// 取较大值是为了保证倾斜框的四个角都被包含，宁可多裁几个像素的白边，
/// 也不能把字的边缘裁掉。
({int width, int height}) cropSizeOf(List<ui.Offset> ordered) {
  final double w1 = (ordered[0] - ordered[1]).distance;
  final double w2 = (ordered[2] - ordered[3]).distance;
  final double h1 = (ordered[0] - ordered[3]).distance;
  final double h2 = (ordered[1] - ordered[2]).distance;
  return (width: math.max(w1, w2).toInt(), height: math.max(h1, h2).toInt());
}

/// 用透视变换把四边形区域裁成水平矩形。
///
/// 越界像素复制最近边缘：填黑会让识别模型看到训练分布之外的强负响应，
/// 在字的外沿制造出不存在的笔画。
img.Image cropByPerspective(
  img.Image source,
  List<ui.Offset> quad,
  int outWidth,
  int outHeight,
) {
  final img.Image out = img.Image(width: outWidth, height: outHeight);
  final PerspectiveWarp? warp = PerspectiveWarp.forQuad(quad, outWidth, outHeight);
  if (warp == null) {
    return out;
  }
  for (int y = 0; y < outHeight; y++) {
    for (int x = 0; x < outWidth; x++) {
      final ui.Offset src = warp.sourceAt(x.toDouble(), y.toDouble());
      final _Rgb8 px = _sampleNearestOrBilinear(source, src.dx, src.dy);
      out.setPixelRgb(x, y, px.r, px.g, px.b);
    }
  }
  return out;
}

/// 双线性插值采样，缩放时比取整采样更能保住笔画边缘。
_Rgb8 _sampleNearestOrBilinear(img.Image source, double x, double y) {
  final double fx = x.clamp(0.0, source.width - 1.0);
  final double fy = y.clamp(0.0, source.height - 1.0);
  final int x0 = fx.floor();
  final int y0 = fy.floor();
  final int x1 = math.min(x0 + 1, source.width - 1);
  final int y1 = math.min(y0 + 1, source.height - 1);
  final double wx = fx - x0;
  final double wy = fy - y0;

  final img.Pixel p00 = source.getPixel(x0, y0);
  final img.Pixel p10 = source.getPixel(x1, y0);
  final img.Pixel p01 = source.getPixel(x0, y1);
  final img.Pixel p11 = source.getPixel(x1, y1);

  num mix(num a, num b, num c, num d) =>
      a * (1 - wx) * (1 - wy) + b * wx * (1 - wy) + c * (1 - wx) * wy + d * wx * wy;

  return _Rgb8(
    mix(p00.r, p10.r, p01.r, p11.r).round(),
    mix(p00.g, p10.g, p01.g, p11.g).round(),
    mix(p00.b, p10.b, p01.b, p11.b).round(),
  );
}

class _Rgb8 {
  const _Rgb8(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}

/// 估算文本在「字宽（em）」单位下的宽度。
///
/// 用于在多候选之间判断「哪一份读数与区域宽高比更契合」，从而挑出少读字、
/// 多读字的错误候选。
double estimateTextWidthInEm(String text) {
  double em = 0;
  for (final int rune in text.runes) {
    em += _codepointEmWidth(rune);
  }
  return em;
}

/// 单个码位的经验字宽。
///
/// 中日韩文字与全角符号按 1em 计；ASCII 中窄字符（i、j、k、l 与 `.`、`,`、
/// `'`）约 0.3em、空格 0.5em、其余字母数字约 0.6em。比例只用于判断读数
/// 与区域宽高比是否大致吻合，不需要精确到单个字符。
double _codepointEmWidth(int cp) {
  if (cp == 0xFFFD) {
    return 0;
  }
  if (cp < 0x80) {
    if (cp == 0x20) return 0.5;
    if (cp >= 0x69 && cp <= 0x6C) return 0.3;
    if (cp == 0x2E || cp == 0x2C || cp == 0x27) return 0.3;
    return 0.6;
  }
  if (cp >= 0x3000 && cp <= 0x9FFF) return 1.0;
  if (cp >= 0xF900 && cp <= 0xFAFF) return 1.0;
  if (cp >= 0xFF00 && cp <= 0xFF60) return 1.0;
  if (cp >= 0xA0 && cp <= 0x206F) return 0.7;
  return 0.7;
}

/// 两个多边形的交并面积比，用于跨分支去重。
double polygonIoU(List<ui.Offset> a, List<ui.Offset> b) {
  final ui.Rect ra = OcrGeometry.boundsOf(a);
  final ui.Rect rb = OcrGeometry.boundsOf(b);
  final ui.Rect inter = ra.intersect(rb);
  if (inter.width <= 0 || inter.height <= 0) {
    return 0;
  }
  final double interArea = inter.width * inter.height;
  final double unionArea = ra.width * ra.height + rb.width * rb.height - interArea;
  return unionArea <= 0 ? 0 : interArea / unionArea;
}

/// 小多边形被大多边形覆盖的比例，用于「同一片文字只留一个框」。
double containmentRatio(List<ui.Offset> inner, List<ui.Offset> outer) {
  final ui.Rect ri = OcrGeometry.boundsOf(inner);
  final ui.Rect ro = OcrGeometry.boundsOf(outer);
  final double area = ri.width * ri.height;
  if (area <= 0) {
    return 0;
  }
  final ui.Rect inter = ri.intersect(ro);
  if (inter.width <= 0 || inter.height <= 0) {
    return 0;
  }
  return (inter.width * inter.height) / area;
}

/// 把多边形沿四边外扩，并夹到图像范围内。
///
/// [extraX]/[extraY] 是行向与纵向的附加外扩量，用于「水平文本横向多给一截」
/// 这种方向性的补边需求。
List<ui.Offset> padPolygon(
  List<ui.Offset> quad,
  double pad,
  int imageWidth,
  int imageHeight, {
  double extraX = 0,
  double extraY = 0,
}) {
  final double px = pad + extraX;
  final double py = pad + extraY;
  if (px <= 0 && py <= 0) {
    return List<ui.Offset>.of(quad);
  }
  final ui.Rect r = OcrGeometry.boundsOf(quad);
  final double maxX = imageWidth - 1.0;
  final double maxY = imageHeight - 1.0;
  return <ui.Offset>[
    ui.Offset((r.left - px).clamp(0.0, maxX), (r.top - py).clamp(0.0, maxY)),
    ui.Offset((r.right + px).clamp(0.0, maxX), (r.top - py).clamp(0.0, maxY)),
    ui.Offset((r.right + px).clamp(0.0, maxX), (r.bottom + py).clamp(0.0, maxY)),
    ui.Offset((r.left - px).clamp(0.0, maxX), (r.bottom + py).clamp(0.0, maxY)),
  ];
}
