import 'dart:convert';
import 'model_reader.dart';

/// CTC 解码器：把识别模型输出的概率张量转换为文本。
///
/// 索引 0 为 CTC blank，后续类别与字典对应，最后一类为空格。
/// 模型输出类别数必须等于字典字符数加二。
class CtcDecoder {
  /// 用给定的字典创建解码器；下标 0 对应模型类别 1。
  ///
  /// 通用入口请使用 [load]，此处公开构造便于单元测试注入小字典。
  CtcDecoder(this._characters);

  /// 模型字典文件的资源路径，与 pubspec 中的声明保持一致。
  static const String dictAssetPath = 'assets/models/ppocr_dict.txt';

  /// CTC 空白符类别索引。
  static const int blankIndex = 0;

  /// 字典内容，下标 0 对应模型类别 1。
  final List<String> _characters;

  /// 从资源加载字典；文件为空或读取失败时抛出异常。
  static Future<CtcDecoder> load([String path = dictAssetPath]) async {
    final String raw = await _readText(path);
    final List<String> characters = raw
        .replaceAll('\r\n', '\n')
        .split('\n')
      ..removeWhere((String line) => line.isEmpty);
    if (characters.isEmpty) {
      throw StateError('Character dictionary is empty: $path');
    }
    return CtcDecoder(characters);
  }

  /// 根据路径类型读取字典，绝对路径不写入应用缓存。
  static Future<String> _readText(String path) {
    return readModelBytes(path).then((data) => utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)));
  }

  /// 字典字符数量，用于校验模型输出维度。
  int get dictionarySize => _characters.length;

  /// 解码单个样本的输出。
  ///
  /// [timesteps] 为时间步数量，[classCount] 为每个时间步的类别数，
  /// [data] 为按 `[T, C]` 顺序展开的扁平数据。返回文本与平均置信度。
  /// 可直接读取插件的数值列表，避免为解码再创建整份 Float32 数组。
  DecodedText decode(List<num> data, int timesteps, int classCount) {
    if (classCount <= 1 || timesteps <= 0) {
      return const DecodedText(text: '', confidence: 0);
    }

    final StringBuffer buffer = StringBuffer();
    double scoreSum = 0;
    int scoreCount = 0;
    int previousIndex = -1;

    for (int t = 0; t < timesteps; t++) {
      final int offset = t * classCount;
      int bestIndex = 0;
      double bestScore = data[offset].toDouble();
      for (int c = 1; c < classCount; c++) {
        final double value = data[offset + c].toDouble();
        if (value > bestScore) {
          bestScore = value;
          bestIndex = c;
        }
      }

      // CTC 规则：跳过空白符，并合并连续重复的同一字符。
      if (bestIndex != blankIndex && bestIndex != previousIndex) {
        buffer.write(_characterAt(bestIndex, classCount));
        scoreSum += bestScore;
        scoreCount++;
      }
      previousIndex = bestIndex;
    }

    return DecodedText(
      text: buffer.toString(),
      confidence: scoreCount == 0 ? 0 : scoreSum / scoreCount,
    );
  }

  /// 把模型类别索引换算为字符。
  ///
  /// 模型类别布局固定为：0 为 blank、1..字典长度 对应字典、最后一个类别为空格。
  String _characterAt(int index, int classCount) {
    final int dictIndex = index - 1;
    if (dictIndex < _characters.length) {
      return _characters[dictIndex];
    }
    return index == classCount - 1 ? ' ' : '';
  }
}

/// 单行文本的解码结果。
class DecodedText {
  const DecodedText({required this.text, required this.confidence});

  final String text;
  final double confidence;
}
