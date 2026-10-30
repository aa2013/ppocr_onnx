<p align="center">
  <a href="./README.md">简体中文</a> | English
</p>

# ppocr_onnx

PP-OCR ONNX provides model loading, text detection, and text recognition.

## Model Preparation

**This package does not include models. Download the detection model, recognition model, and matching dictionary separately. It has been tested with PP-OCRv6.**

Rename the three files to `ppocr_det.onnx`, `ppocr_rec.onnx`, and `ppocr_dict.txt`, and place them in the same directory. On native platforms, you can pass the absolute path to this directory directly.

The current `example` application includes the `ppocrv6-tiny` models.

To use Flutter assets, place the files in `assets/models/` and declare them in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/models/
```

## Usage

```dart
import 'package:ppocr_onnx/ppocr_onnx.dart';

final engine = OcrEngine(modelPath: 'assets/models');
await engine.load();
final result = await engine.run(imageBytes); // Fast mode by default
for (final line in result.lines) {
  print('${line.text}: ${line.confidence}, ${line.polygon}');
}
await engine.dispose();
await engine.load(); // The same instance can be initialized again
await engine.dispose();
```

The directory must contain `ppocr_det.onnx`, `ppocr_rec.onnx`, and `ppocr_dict.txt`. If any file is missing, its path is reported before session creation.
Relative paths refer to Flutter asset directories and must be declared in the host application's pubspec. On native platforms, absolute paths are read directly from the filesystem.
The default path is `assets/models`; initialization fails if the models have not been provided.

`load()` returns 0 for an already-loaded instance.
After replacing files, call `dispose()` followed by `load()`.
Each new initialization reads the model resources again. Native loading behavior depends on the model source:

- **Absolute filesystem directory**: Model file paths are passed directly to ONNX Runtime.
- **Flutter assets**: An asset key identifies a resource, not necessarily a regular file that native APIs can open directly (for example, a resource inside an Android APK). The native interface of the ONNX plugin currently used requires a file path, so asset bytes are first read and written to a separate temporary directory, then sessions are created from those temporary files.

Separate temporary directories isolate loading across instances and prevent files with the same name from overwriting each other. Temporary files are cleaned up after session creation, and cleanup is also attempted if initialization fails. Files may remain if the process is forcibly terminated or cleanup fails, but subsequent initializations do not actively reuse those leftover files.
Here, “no reusable on-disk model cache” means extracted files are not retained for the next initialization; it **does not mean loading avoids disk writes**. Each new initialization from assets requires extraction again, adding disk I/O.

Once created, a session retains the model state required for inference. The same engine reuses its sessions across multiple images rather than extracting or loading models for each recognition request. Calling `load()` after `dispose()` initializes the engine again.
Web does not use this native temporary-file flow. Instead, asset keys are resolved to resource URLs and loaded by ONNX Runtime Web; browser HTTP caching may still apply.

## Background Execution

```dart
final worker = OcrWorker(modelPath: 'assets/models');
final loadMillis = await worker.start();
final result = await worker.run(imageBytes, mode: OcrMode.accurate);
await worker.dispose();
```

On native platforms, the worker creates and releases ONNX sessions in a separate isolate and returns complete `OcrResult` and `OcrDiagnostics` objects.
Start the worker from the main isolate. When using assets, the main isolate writes both models and the dictionary to a separate temporary directory. The worker loads them through absolute paths, and the temporary directory is cleaned up when initialization finishes. When an absolute filesystem directory is supplied, source files are used directly without copying or deletion.
A regular engine can also run in an isolate with a registered BackgroundIsolateBinaryMessenger, but absolute paths must be supplied.
The worker processes requests serially and supports coalescing concurrent `start()` calls, retrying after failures, and repeated start/dispose cycles. `dispose()` waits for in-flight tasks.
The regular engine rejects concurrent `run()` calls. The underlying platform plugin may still perform inference on a platform thread, so a background Dart isolate does not guarantee a completely non-blocking UI thread on every platform.

## Recognition Results

- `OcrLine`: Text, recognition confidence, a quadrilateral, and a bounding rectangle in original-image pixel coordinates.
- `OcrResult`: Lines in reading order, full text, detection/recognition/total timings, and per-step diagnostics.

The example includes image selection, model directory selection, copying image/model paths, copying full text, switching between fast and accurate modes, synchronized highlighting between the preview and result list, and timing information.

## Platforms and Dependencies

| Platform | Model source | Worker |
| --- | --- | --- |
| Android / iOS / Windows / macOS / Linux | Assets or accessible absolute filesystem directories | Separate Dart isolate |
| Web | Declared Flutter assets | Current event loop; browsers do not support Isolate.spawn |

The Web host must load ONNX Runtime Web before Flutter starts; see [example/web/index.html](./example/web/index.html).
The example uses a pinned CDN version. For offline deployment, host the JS/WASM files yourself. Browsers do not support system absolute paths or native directory selection.
On mobile platforms, only directories accessible to the application can be read; the host application is responsible for file permissions. The default CPU provider is used, and no unverified GPU fallback behavior is guaranteed.

## Validation

```powershell
flutter analyze
flutter test
cd example
flutter test test/widget_test.dart
flutter build windows
flutter build web --no-wasm-dry-run
flutter run -d windows --profile -t integration_test/worker_test.dart
```
Execution can be very slow in Debug mode. Use `profile` mode for validation.
