import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import 'perspective.dart';

/// OCR 图像预处理：负责检测与识别两个模型的输入张量构造。
///
/// 通道顺序、归一化参数与缩放策略全部取自官方 inference.yml 与
/// `resize_norm_img_chinese`，任何一处不一致都会导致识别结果乱码。
class OcrPreprocessor {
  OcrPreprocessor._();

  /// 检测输入的边长上限。
  static const int detLimitSideLen = 960;

  /// 检测与识别模型都要求输入边长是 32 的整数倍。
  static const int sizeAlignUnit = 32;

  /// 识别模型输入高度固定为 48。
  static const int recInputHeight = 48;

  /// 识别输入的宽度下限：极短文本条也要撑到该宽度，否则模型缺少上下文。
  static const int recMinInputWidth = 32;

  /// 识别输入的最大宽度，防止超长文本产生过大的张量。
  static const int recMaxInputWidth = 2048;

  /// 检测模型归一化均值，按 BGR 顺序。
  static const List<double> detMean = <double>[0.485, 0.456, 0.406];

  /// 检测模型归一化标准差，按 BGR 顺序。
  static const List<double> detStd = <double>[0.229, 0.224, 0.225];

  static img.Image decode(Uint8List bytes) {
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) {
      throw const FormatException('Unsupported or corrupted image file');
    }
    return decoded;
  }

  /// 由任意位图构造检测输入：返回张量数据与使用的输入尺寸。
  ///
  /// 等比缩放到长边不超过 [detLimitSideLen]，再把宽高向上对齐到
  /// [sizeAlignUnit] 的倍数。补边区域填白色，因为网页与文档截图的背景
  /// 基本都是白色，用黑色填充会引入模型未见过的强负响应，导致靠近边缘的
  /// 文字漏检。
  static DetInput buildDetInput(img.Image source) {
    final int srcW = source.width;
    final int srcH = source.height;
    final int maxSide = math.max(srcW, srcH);
    final double ratio =
        maxSide > detLimitSideLen ? detLimitSideLen / maxSide : 1.0;

    final int resizedW = math.max(1, (srcW * ratio).round());
    final int resizedH = math.max(1, (srcH * ratio).round());
    final int inputW = _alignUp(resizedW, sizeAlignUnit);
    final int inputH = _alignUp(resizedH, sizeAlignUnit);

    final img.Image resized = img.copyResize(
      source,
      width: resizedW,
      height: resizedH,
      interpolation: img.Interpolation.linear,
    );

    final int planeSize = inputW * inputH;
    final Float32List data = Float32List(planeSize * 3);
    // 补边区域填白色，与截图背景一致。
    for (int i = 0; i < planeSize; i++) {
      data[i] = (1.0 - detMean[0]) / detStd[0];
      data[planeSize + i] = (1.0 - detMean[1]) / detStd[1];
      data[planeSize * 2 + i] = (1.0 - detMean[2]) / detStd[2];
    }
    for (int y = 0; y < resizedH; y++) {
      final int rowOffset = y * inputW;
      for (int x = 0; x < resizedW; x++) {
        final img.Pixel pixel = resized.getPixel(x, y);
        final int r = pixel.r.toInt();
        final int g = pixel.g.toInt();
        final int b = pixel.b.toInt();
        final int index = rowOffset + x;
        // image 包按 RGB 存储，模型要求 BGR，这里交换 R 与 B 两个通道。
        data[index] = ((b / 255.0) - detMean[0]) / detStd[0];
        data[planeSize + index] = ((g / 255.0) - detMean[1]) / detStd[1];
        data[planeSize * 2 + index] = ((r / 255.0) - detMean[2]) / detStd[2];
      }
    }

    return DetInput(
      data: data,
      width: inputW,
      height: inputH,
      // 检测输出与输入网格一一对应，补边区域也参与映射，
      // 因此原图坐标需按「原始尺寸 / 输入尺寸」整体换算。
      scaleX: srcW / inputW,
      scaleY: srcH / inputH,
    );
  }

  /// 从四边形区域裁剪出识别模型输入张量。
  ///
  /// 先按点排序做透视变换裁成水平矩形，再等比缩放到模型固定的 48 高、
  /// 宽度不足时右侧补白色，最后归一化。透视变换而非双线性映射是关键：
  /// 倾斜文本行用双线性映射会把字横向拉歪。
  ///
  /// 高度不能改：模型的输入高度是固定的 48，抬高会被 ORT 直接拒绝。
  static Float32List buildRecInput(img.Image source, List<ui.Offset> quad) {
    final List<ui.Offset> ordered = orderQuadByYThenX(quad);
    final ({int width, int height}) cropSize = cropSizeOf(ordered);
    if (cropSize.width <= 0 || cropSize.height <= 0) {
      return Float32List(0);
    }

    final img.Image crop = cropByPerspective(
      source,
      ordered,
      cropSize.width,
      cropSize.height,
    );

    // 等比缩放到固定高度；超宽文本只能横向压缩，否则张量尺寸失控。
    final double ratio = recInputHeight / crop.height;
    final int scaledW = (crop.width * ratio).toInt();
    final int outW = math.max(recMinInputWidth, math.min(scaledW, recMaxInputWidth));
    const int outH = recInputHeight;
    final img.Image resized = img.copyResize(
      crop,
      width: scaledW.clamp(1, recMaxInputWidth),
      height: outH,
      interpolation: img.Interpolation.linear,
    );

    final int plane = outW * outH;
    final Float32List data = Float32List(plane * 3);
    // 补边填白色（归一化后为 +1），与文档截图的纸面一致；填黑会让模型看到
    // 训练分布之外的强负响应。
    for (int i = 0; i < plane; i++) {
      data[i] = 1.0;
      data[plane + i] = 1.0;
      data[plane * 2 + i] = 1.0;
    }

    final int copyW = math.min(resized.width, outW);
    for (int y = 0; y < outH; y++) {
      for (int x = 0; x < copyW; x++) {
        final img.Pixel p = resized.getPixel(x, y);
        final int index = y * outW + x;
        // 识别模型要求 BGR 顺序，且缩放到 [-1, 1]（等价 mean=0.5、std=0.5）。
        data[index] = p.b / 127.5 - 1.0;
        data[plane + index] = p.g / 127.5 - 1.0;
        data[plane * 2 + index] = p.r / 127.5 - 1.0;
      }
    }
    return data;
  }

  /// 识别输入的目标宽度，必须与 [buildRecInput] 返回的张量宽度一致。
  static int recOutputWidth(List<ui.Offset> quad) {
    final List<ui.Offset> ordered = orderQuadByYThenX(quad);
    final ({int width, int height}) cropSize = cropSizeOf(ordered);
    if (cropSize.width <= 0 || cropSize.height <= 0) {
      return recMinInputWidth;
    }
    final int scaledW = (cropSize.width * (recInputHeight / cropSize.height)).toInt();
    return math.max(recMinInputWidth, math.min(scaledW, recMaxInputWidth));
  }

  /// 把数值向上对齐到 [unit] 的整数倍。
  static int _alignUp(int value, int unit) =>
      ((value + unit - 1) ~/ unit) * unit;
}

/// 检测模型输入张量及其与原始图片的坐标换算比例。
class DetInput {
  const DetInput({
    required this.data,
    required this.width,
    required this.height,
    required this.scaleX,
    required this.scaleY,
  });

  /// 形状为 [1, 3, height, width] 的扁平数据。
  final Float32List data;
  final int width;
  final int height;

  /// 原图坐标与检测输入坐标之间的比例，用于把结果映射回原图。
  final double scaleX;
  final double scaleY;
}
