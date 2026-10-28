import 'dart:math' as math;
import 'dart:ui' as ui;

/// DB 文本检测结果的几何处理工具。
class OcrGeometry {
  OcrGeometry._();

  /// 求点集的凸包，返回逆时针顺序的顶点。
  static List<ui.Offset> convexHull(List<ui.Offset> points) {
    if (points.length < 3) {
      return List<ui.Offset>.of(points);
    }
    final List<ui.Offset> sorted = List<ui.Offset>.of(points)
      ..sort((ui.Offset a, ui.Offset b) {
        final int byX = a.dx.compareTo(b.dx);
        return byX != 0 ? byX : a.dy.compareTo(b.dy);
      });

    final List<ui.Offset> lower = <ui.Offset>[];
    for (final ui.Offset p in sorted) {
      while (lower.length >= 2 &&
          _cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }

    final List<ui.Offset> upper = <ui.Offset>[];
    for (final ui.Offset p in sorted.reversed) {
      while (upper.length >= 2 &&
          _cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }

    lower.removeLast();
    upper.removeLast();
    return <ui.Offset>[...lower, ...upper];
  }

  /// 求点集的最小面积外接矩形，返回四个顶点。
  ///
  /// 最小面积外接矩形必有一条边与凸包某条边共线，因此遍历每条凸包边，
  /// 把点投影到该边的方向与法线方向取包围盒，面积最小者即为结果。
  static List<ui.Offset> minAreaRect(List<ui.Offset> points) {
    final List<ui.Offset> hull = convexHull(points);
    if (hull.isEmpty) {
      return <ui.Offset>[];
    }
    if (hull.length == 1) {
      return <ui.Offset>[hull[0], hull[0], hull[0], hull[0]];
    }
    if (hull.length == 2) {
      return <ui.Offset>[hull[0], hull[1], hull[1], hull[0]];
    }

    double bestArea = double.infinity;
    List<ui.Offset> bestRect = <ui.Offset>[];

    for (int i = 0; i < hull.length; i++) {
      final ui.Offset p0 = hull[i];
      final ui.Offset p1 = hull[(i + 1) % hull.length];
      final double dx = p1.dx - p0.dx;
      final double dy = p1.dy - p0.dy;
      final double length = math.sqrt(dx * dx + dy * dy);
      if (length < 1e-6) {
        continue;
      }
      final double ux = dx / length;
      final double uy = dy / length;
      final double vx = -uy;
      final double vy = ux;

      double minU = double.infinity;
      double maxU = -double.infinity;
      double minV = double.infinity;
      double maxV = -double.infinity;
      for (final ui.Offset p in hull) {
        final double pu = p.dx * ux + p.dy * uy;
        final double pv = p.dx * vx + p.dy * vy;
        if (pu < minU) minU = pu;
        if (pu > maxU) maxU = pu;
        if (pv < minV) minV = pv;
        if (pv > maxV) maxV = pv;
      }

      final double area = (maxU - minU) * (maxV - minV);
      if (area < bestArea) {
        bestArea = area;
        ui.Offset toXY(double pu, double pv) =>
            ui.Offset(pu * ux + pv * vx, pu * uy + pv * vy);
        bestRect = <ui.Offset>[
          toXY(minU, minV),
          toXY(maxU, minV),
          toXY(maxU, maxV),
          toXY(minU, maxV),
        ];
      }
    }

    return bestRect;
  }

  /// 把多边形顶点整理为左上、右上、右下、左下的固定顺序。
  ///
  /// 先按相对质心的角度排序，再以 x+y 最小的顶点为起点；x+y 最小值是
  /// 左上角的近似，适用于水平文本框。
  static List<ui.Offset> orderQuad(List<ui.Offset> quad) {
    if (quad.length != 4) {
      return List<ui.Offset>.of(quad);
    }
    double cx = 0;
    double cy = 0;
    for (final ui.Offset p in quad) {
      cx += p.dx;
      cy += p.dy;
    }
    cx /= 4;
    cy /= 4;

    final List<ui.Offset> sorted = List<ui.Offset>.of(quad)
      ..sort((ui.Offset a, ui.Offset b) {
        final double angleA = math.atan2(a.dy - cy, a.dx - cx);
        final double angleB = math.atan2(b.dy - cy, b.dx - cx);
        return angleA.compareTo(angleB);
      });

    int startIndex = 0;
    double bestScore = double.infinity;
    for (int i = 0; i < sorted.length; i++) {
      final double score = sorted[i].dx + sorted[i].dy;
      if (score < bestScore) {
        bestScore = score;
        startIndex = i;
      }
    }
    return <ui.Offset>[
      for (int i = 0; i < 4; i++) sorted[(startIndex + i) % 4],
    ];
  }

  /// 求点集的轴对齐外接矩形。
  static ui.Rect boundsOf(List<ui.Offset> points) {
    if (points.isEmpty) {
      return ui.Rect.zero;
    }
    double minX = points.first.dx;
    double maxX = points.first.dx;
    double minY = points.first.dy;
    double maxY = points.first.dy;
    for (final ui.Offset p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }
    return ui.Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  static double _cross(ui.Offset o, ui.Offset a, ui.Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
}
