# PP-OCR ONNX example

```powershell
flutter pub get
flutter run -d windows
```

The example uses OcrWorker, OcrOverlayViewer and OcrTimingDetails from the public package API.
Choose an image, optionally choose a model directory, then run OCR.
The required model files are ppocr_det.onnx, ppocr_rec.onnx and ppocr_dict.txt.

The package does not ship models. Download matching models yourself; PP-OCRv6 has been tested.
For asset mode and real-model integration tests, place the three files in example/assets/models/ and declare assets/models/ under flutter.assets in this example’s pubspec.yaml. Native platforms can instead choose an absolute model directory.

Web uses host-provided assets and a CDN-hosted ONNX Runtime Web script. It does not access native directories.
See the package README for lifecycle, platform limitations and test commands.
