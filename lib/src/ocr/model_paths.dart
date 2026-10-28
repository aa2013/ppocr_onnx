/// OCR 模型目录配置。
class OcrModelPaths {
  const OcrModelPaths(this.directory);

  /// 默认由宿主应用声明的模型目录；包本身不携带模型。
  const OcrModelPaths.defaults() : directory = 'assets/models';

  static const detFilename = 'ppocr_det.onnx';
  static const recFilename = 'ppocr_rec.onnx';
  static const dictFilename = 'ppocr_dict.txt';

  final String directory;

  String get det => _join(detFilename);
  String get rec => _join(recFilename);
  String get dict => _join(dictFilename);

  /// 连接固定文件名，兼容末尾的两种平台分隔符。
  String _join(String file) => directory.endsWith('/') || directory.endsWith('\\')
      ? '$directory$file'
      : '$directory/$file';
}
