import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'model_paths.dart';

/// 从绝对文件或 asset 读取当前内容；后台 isolate 使用已注册的 messenger。
Future<ByteData> readModelBytes(String path) async {
  try {
    if (!kIsWeb && File(path).isAbsolute) {
      final bytes = await File(path).readAsBytes();
      return ByteData.sublistView(bytes);
    }
    if (!kIsWeb && RootIsolateToken.instance == null) {
      throw UnsupportedError('Use absolute model paths in a background isolate, or use OcrWorker');
    }
    return await rootBundle.load(path);
  } catch (error) {
    throw StateError('Cannot read OCR model file "$path": $error');
  }
}

/// 在创建原生会话前检查全部必需文件，避免部分初始化掩盖缺失路径。
Future<void> validateModels(OcrModelPaths paths) async {
  for (final path in <String>[paths.det, paths.rec, paths.dict]) {
    if (!kIsWeb && File(path).isAbsolute) {
      if (!await File(path).exists()) throw StateError('Missing OCR model file: $path');
    } else {
      await readModelBytes(path);
    }
  }
}
