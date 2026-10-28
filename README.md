# ppocr_onnx

PP-OCR ONNX 提供模型加载、文本检测与识别、后台 worker，以及可复用的识别框预览组件。

## 模型准备

**包本身不携带模型，需要自行下载检测模型、识别模型和配套字典。目前已在 PP-OCRv6 上测试通过。**

下载后将三个文件命名为 `ppocr_det.onnx`、`ppocr_rec.onnx`、`ppocr_dict.txt` 并放在同一目录。原生平台可以直接传入该目录的绝对路径。

如使用 assets，请将文件放入宿主应用的 `assets/models/`，并在宿主 `pubspec.yaml` 中声明：

```yaml
flutter:
  assets:
    - assets/models/
```

运行 example 的 asset 模式和真实模型集成测试前，需要自行把模型放入 `example/assets/models/` 并添加上述资源声明；原生 example 也可直接选择本地模型目录。模型目录已加入 Git 忽略规则。

## SDK 要求

在保持当前已解析的直接、间接依赖版本不变的前提下，插件与 example 的约束为：

```yaml
environment:
  sdk: ^3.13.0
  flutter: '>=3.38.4'
```

Dart 下限来自 `web 1.1.2`（`>=3.13.0 <4.0.0`），Flutter 下限来自 `path_provider_foundation 2.6.0`（`>=3.38.4`）。两者必须同时满足：Flutter 3.38.4 本身不代表已满足 Dart 要求，需要使用自带 Dart 3.13.0 或更新版本的 Flutter SDK。
这些是当前依赖组合的要求，不只是 `flutter_onnxruntime` 自身的要求；没有为降低 SDK 门槛降级依赖。

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
默认路径 `assets/models` 属于宿主应用，包内没有预置模型；未准备模型时初始化会报错。

模型必须符合当前 PP-OCR 流水线：检测为 DB 概率图、BGR/ImageNet 归一化，识别输入高度 48，CTC 输出类别数为字典长度加二（blank、字符、space）。输入/输出名称取自会话。固定文件名不限定 OCR 版本，但更换模型仍需匹配这些约定。

`load()` 对已加载实例返回 0；替换文件后先 `dispose()` 再 `load()`。每次新的初始化重新读取目录。Assets 在原生端使用独立临时文件，创建会话后删除，不读写可复用的模型磁盘缓存。
原生会话只在同一个引擎中复用；不在每次图片识别时重新创建模型。

## 后台运行

```dart
final worker = OcrWorker(modelPath: 'assets/models');
final loadMillis = await worker.start();
final result = await worker.run(imageBytes, mode: OcrMode.accurate);
await worker.dispose();
```

原生平台的 worker 在独立 isolate 创建和释放 ONNX 会话，返回完整 `OcrResult` 和 `OcrDiagnostics`。
调用从主 isolate 发起；assets 由主 isolate 写入独立临时目录，模型初始化完成即删除临时目录。
普通引擎也可在已注册 BackgroundIsolateBinaryMessenger 的 isolate 中使用，但须传绝对路径。
worker 串行处理请求，支持并发 start 合并、失败后重试和重复启停；dispose 等待在途任务。
普通引擎拒绝并发 run。底层平台插件仍可能在平台线程执行推理，后台 Dart isolate 不保证所有平台 UI 线程完全无阻塞。

## 结果与 widgets

- `OcrLine`：文本、识别置信度、原图像素坐标中的四边形和外接矩形。
- `OcrResult`：按阅读顺序排列的行、全文、检测/识别/总耗时，以及分步骤诊断。
- `OcrOverlayViewer`：ImageProvider、原图尺寸、结果行；通过 `hoveredIndex`、`onHovered`、`onSelected` 与任意列表联动。按 contain 变换绘制并按实际多边形命中。
- `OcrTimingDetails`：英文耗时明细折叠面板。

example 保留图片选择、模型目录选择、图片/模型路径复制、全文复制、快速/高精度切换、预览与结果列表双向高亮以及耗时信息。

## 平台与依赖

| 平台 | 模型来源 | Worker |
| --- | --- | --- |
| Android / iOS / Windows / macOS / Linux | assets、可访问的绝对文件目录 | 独立 Dart isolate |
| Web | 声明的 Flutter assets | 当前事件循环；浏览器不支持 Isolate.spawn |

唯一直接原生插件依赖是 `flutter_onnxruntime`；`image` 和 `clipper2` 是 Dart 算法库。
运行时插件自身传递依赖 `path_provider`，本包不通过它缓存模型。文件选择仅由 example 依赖 `file_picker`。
本包采用 Flutter Dart package 外观封装原生插件，不增加无业务用途的 MethodChannel 或平台样板代码。

Web 宿主需在 Flutter 启动前加载 ONNX Runtime Web，见 example/web/index.html。示例使用固定版本 CDN，离线部署需自行托管 JS/WASM。浏览器不支持系统绝对路径和原生目录选择。
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

Windows profile 下验证了 worker assets 加载、重复启停、真实识别与诊断、绝对路径引擎、重载和在途释放。
调试模式的集成测试运行器可能暂停新 isolate，真实 worker 验证使用上述 profile 命令，结束后退出运行窗口。
其他原生平台需要对应设备/构建主机验证；Web 构建通过不等于浏览器真实推理验证。
原 demo 的算法和真实图片回归测试均保留在 test 与 example/integration_test 中；原来的坐标近似断言没有放宽。

本次原始高精度回归仍在坐标断言失败：left=0，而旧断言要求 60±40。这与原 demo 已记录的识别窗扩展问题一致；断言保留，未通过放宽断言掩盖。
