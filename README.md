<p align="center">
  简体中文 | <a href="README.EN.md">English</a>
</p>

# ppocr_onnx

PP-OCR ONNX 提供模型加载、文本检测与识别

## 模型准备

**包本身不携带模型，需要自行下载检测模型、识别模型和配套字典。目前已在 PP-OCRv6 上测试通过。**

下载后将三个文件命名为 `ppocr_det.onnx`、`ppocr_rec.onnx`、`ppocr_dict.txt` 并放在同一目录。原生平台可以直接传入该目录的绝对路径。

当前 `example` 应用中预置的是 `ppocrv6-tiny` 模型

如使用 assets，请将文件放入 `assets/models/`，并在 `pubspec.yaml` 中声明：

```yaml
flutter:
  assets:
    - assets/models/
```

## 使用

```dart
import 'package:ppocr_onnx/ppocr_onnx.dart';

final engine = OcrEngine(modelPath: 'assets/models');
await engine.load();
final result = await engine.run(imageBytes); // 默认快速模式
for (final line in result.lines) {
  print('${line.text}: ${line.confidence}, ${line.polygon}');
}
await engine.dispose();
await engine.load(); // 同一实例可以重新初始化
await engine.dispose();
```

目录内固定包含 `ppocr_det.onnx`、`ppocr_rec.onnx`、`ppocr_dict.txt`，缺少任何文件会在创建会话前报出路径。
相对路径为 Flutter asset 目录，需要在宿主 pubspec 中声明；原生平台绝对路径直接读取文件。
默认路径 `assets/models`; 未准备模型时初始化会报错。

`load()` 对已加载实例返回 0；
替换文件后先 `dispose()` 再 `load()`。
每次新的初始化重新读取模型资源。原生端的加载方式取决于模型来源：

- **绝对文件目录**：直接将模型文件路径传给 ONNX Runtime。
- **Flutter assets**：asset key 是资源标识，不保证对应可由原生接口直接打开的普通文件（例如 Android APK 内的资源）。当前使用的 ONNX 插件原生接口需要文件路径，因此先读取 asset 字节，写入独立临时目录，再从临时文件创建会话。

独立临时目录用于隔离不同实例的加载，避免同名文件互相覆盖。创建会话后会清理临时文件，初始化失败时也会尝试清理；进程被强制终止或清理失败时可能残留文件，但后续初始化不会主动复用这些残留文件。
这里“不使用可复用的模型磁盘缓存”指不保留提取文件供下次初始化使用，**不代表加载过程不写磁盘**。每次新的 assets 初始化都需要重新提取，代价是额外的磁盘 I/O。

会话创建完成后持有推理所需的模型状态，同一个引擎会复用会话处理多张图片，不会在每次识别时重新提取或加载模型；`dispose()` 后再次 `load()` 才会重新初始化。
Web 不使用上述原生临时文件流程，而是将 asset key 解析为资源 URL 后交给 ONNX Runtime Web 加载；浏览器的 HTTP 缓存仍可能生效。

## 后台运行

```dart
final worker = OcrWorker(modelPath: 'assets/models');
final loadMillis = await worker.start();
final result = await worker.run(imageBytes, mode: OcrMode.accurate);
await worker.dispose();
```

原生平台的 worker 在独立 isolate 创建和释放 ONNX 会话，返回完整 `OcrResult` 和 `OcrDiagnostics`。
调用从主 isolate 发起；使用 assets 时，由主 isolate 将两个模型和字典写入独立临时目录，worker 通过绝对路径加载，初始化结束后清理临时目录。传入绝对文件目录时直接使用源文件，不复制、不删除。
普通引擎也可在已注册 BackgroundIsolateBinaryMessenger 的 isolate 中使用，但须传绝对路径。
worker 串行处理请求，支持并发 start 合并、失败后重试和重复启停；dispose 等待在途任务。
普通引擎拒绝并发 run。底层平台插件仍可能在平台线程执行推理，后台 Dart isolate 不保证所有平台 UI 线程完全无阻塞。

## 识别结果

- `OcrLine`：文本、识别置信度、原图像素坐标中的四边形和外接矩形。
- `OcrResult`：按阅读顺序排列的行、全文、检测/识别/总耗时，以及分步骤诊断。

example 保留图片选择、模型目录选择、图片/模型路径复制、全文复制、快速/高精度切换、预览与结果列表双向高亮以及耗时信息。

## 平台与依赖

| 平台 | 模型来源 | Worker |
| --- | --- | --- |
| Android / iOS / Windows / macOS / Linux | assets、可访问的绝对文件目录 | 独立 Dart isolate |
| Web | 声明的 Flutter assets | 当前事件循环；浏览器不支持 Isolate.spawn |

Web 宿主需在 Flutter 启动前加载 ONNX Runtime Web，见 example/web/index.html。
示例使用固定版本 CDN，离线部署需自行托管 JS/WASM。浏览器不支持系统绝对路径和原生目录选择。
移动平台只能读取应用有权限访问的目录；文件权限由宿主负责。执行默认 CPU provider，不承诺未经验证的 GPU 回退策略。

## 验证

```powershell
flutter analyze
flutter test
cd example
flutter test test/widget_test.dart
flutter build windows
flutter build web --no-wasm-dry-run
flutter run -d windows --profile -t integration_test/worker_test.dart
```
在 Debug 模式下可能会非常耗时，请在 `profile` 模式下验证
