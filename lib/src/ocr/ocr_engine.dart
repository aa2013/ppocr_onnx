import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

import 'branch_preprocessor.dart';
import 'ctc_decoder.dart';
import 'db_postprocess.dart';
import 'image_preprocessor.dart';
import 'ocr_result.dart';
import 'ocr_diagnostics.dart';
import 'result_merger.dart';
import 'model_paths.dart';
import 'model_reader.dart';
import 'model_url.dart'
if (dart.library.js_interop) 'model_url_web.dart';

/// 快速模式只处理原图，高精度保留多分支召回。
enum OcrMode { fast, accurate }

/// PP-OCR 推理引擎：多分支检测 + 逐区域多候选择优识别。
///
/// 每个分支用不同的预处理（原图 / 2x / 3x / CLAHE / 锐化）各做一次检测，
/// 跨分支去重并拼接同行碎片，最后每个区域在「原图 + 各可用分支图」上各
/// 识别一次，按几何契合度择优。单一路径无法同时应付小字、断笔与低对比度，
/// 多分支可提高小字与低对比度文字的召回率。
class OcrEngine {
  /// 创建 OCR 引擎；可传入较少分支以降低实时识别耗时。
  OcrEngine({String? modelPath, List<OcrBranch>? branches})
      : modelPaths = OcrModelPaths(modelPath ?? OcrModelPaths.defaults().directory),
        branches = List<OcrBranch>.unmodifiable(branches ?? defaultBranches);

  /// 当前实例使用的模型目录，目录内必须包含三个固定文件名。
  final OcrModelPaths modelPaths;

  /// 检测模型资源路径。
  static const String detModelAsset = 'ppocr_det.onnx';

  /// 识别模型资源路径。
  static const String recModelAsset = 'ppocr_rec.onnx';

  /// 检测与识别模型的输入张量名，Paddle 导出时固定为 `x`。
  static const String inputName = 'x';

  /// 模型输出张量名，Paddle 导出时固定生成。
  static const String outputName = 'fetch_name_0';

  /// 参与检测的分支配置。
  static const List<OcrBranch> defaultBranches = OcrBranch.surveillance;

  /// 高精度模式参与检测和候选识别的分支配置。
  final List<OcrBranch> branches;

  /// 跨分支合并与识别窗参数。
  static const MergeConfig mergeConfig = MergeConfig();

  final OnnxRuntime _runtime = OnnxRuntime();

  OrtSession? _detSession;
  OrtSession? _recSession;
  CtcDecoder? _decoder;

  /// 仅在整图识别期间启用，单区域接口不产生不完整统计。
  OcrTimingCollector? _activeTiming;

  bool _isRunning = false;
  bool _disposed = false;
  Future<int>? _loading;
  Completer<void>? _runningDone;
  Future<void>? _disposing;

  /// 按模式选择分支，自定义分支用于高精度模式。
  List<OcrBranch> branchesFor(OcrMode mode) => mode == OcrMode.fast
      ? const <OcrBranch>[OcrBranch(kind: OcrBranchKind.raw, name: 'raw')]
      : branches;


  bool get isReady => _detSession != null && _recSession != null && _decoder != null;

  /// 加载两个模型与字典，已加载时直接返回 0。
  ///
  /// 返回本次加载耗时（毫秒），用于界面展示。部分加载成功时会保留已建好的
  /// 会话，重试时只补建缺失的部分。
  Future<int> load() {
    if (_disposing != null) return Future<int>.error(StateError('OCR is disposing'));
    _disposed = false;
    return _loading ??= _loadModels().whenComplete(() => _loading = null);
  }

  /// 合并并发加载，失败时清理本次创建的资源。
  Future<int> _loadModels() async {
    if (isReady) {
      return 0;
    }
    final Stopwatch watch = Stopwatch()..start();
    await validateModels(modelPaths);
    final bool hadDet = _detSession != null;
    final bool hadRec = _recSession != null;
    final bool hadDecoder = _decoder != null;
    try {
      _detSession ??= await _createFreshSession(modelPaths.det);
      _recSession ??= await _createFreshSession(modelPaths.rec);
      _decoder ??= await CtcDecoder.load(modelPaths.dict);
      watch.stop();
      return watch.elapsedMilliseconds;
    } catch (_) {
      // 本次加载失败时只清理本次新建的资源，保留调用方此前已有的会话以便重试。
      if (!hadDet) {
        await _detSession?.close();
        _detSession = null;
      }
      if (!hadRec) {
        await _recSession?.close();
        _recSession = null;
      }
      if (!hadDecoder) {
        _decoder = null;
      }
      rethrow;
    }
  }

  /// 从当前 assetKey 读取模型；独立临时目录避免复用插件的同名旧缓存。
  ///
  /// 原生接口需要文件路径，临时文件仅供本次会话创建使用，加载后立即清理。
  /// Web 通过引擎把 asset key 解析为资源 URL，不进行本地文件操作。
  Future<OrtSession> _createFreshSession(String path) async {
    if (kIsWeb) {
      // ONNX 插件直接请求 URL，不会像 rootBundle 一样补上资源目录。
      return _runtime.createSession(resolveModelUrl(path));
    }
    if (File(path).isAbsolute) {
      if (!await File(path).exists()) {
        throw StateError('OCR model file is missing: $path');
      }
      return _runtime.createSession(path);
    }
    final ByteData data;
    try {
      data = await readModelBytes(path);
    } on FlutterError {
      throw StateError('OCR model asset is missing: $path');
    }
    final Directory directory = await Directory.systemTemp.createTemp('ocr_model_');
    final File file = File('${directory.path}${Platform.pathSeparator}model.onnx');
    try {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      return await _runtime.createSession(file.path);
    } finally {
      // 只清理本次创建的确定路径，不触碰插件缓存或其他应用文件。
      if (await file.exists()) await file.delete();
      await directory.delete();
    }
  }

  /// 等待在途任务完成后释放会话，避免页面退出时提前释放资源。
  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= _disposeWhenIdle().whenComplete(() => _disposing = null);
  }

  /// 加载异常由原调用方处理，释放仍继续执行。
  Future<void> _disposeWhenIdle() async {
    try { await _loading; } catch (_) {}
    await _runningDone?.future;
    try {
      await _detSession?.close();
    } finally {
      try {
        await _recSession?.close();
      } finally {
        _detSession = null;
        _recSession = null;
        _decoder = null;
      }
    }
  }

  /// 占用会话，禁止关闭后的调用和并发识别。
  void _beginRun() {
    if (_disposed || _isRunning || !isReady) {
      throw StateError('OCR unavailable, busy or not loaded');
    }
    _isRunning = true;
    _runningDone = Completer<void>();
  }

  /// 解除占用并唤醒等待释放的调用方。
  void _endRun() {
    _isRunning = false;
    _runningDone?.complete();
    _runningDone = null;
  }

  /// 丢弃没有内容的行。
  static bool _isNoise(OcrLine line) => line.text.trim().isEmpty;

  /// 识别单个四边形区域，返回最优候选。
  ///
  /// 不跑检测，直接在原图与放大分支图上做候选择优，便于对单个区域做
  /// 回归验证。
  Future<OcrLine?> recognizeQuad(Uint8List imageBytes, List<ui.Offset> quad) async {
    _beginRun();
    try {
      final OrtSession? rec = _recSession;
      final CtcDecoder? decoder = _decoder;
      if (rec == null || decoder == null) {
        throw StateError('OCR models are not loaded');
      }
      final img.Image source = await compute(OcrPreprocessor.decode, imageBytes);
      final MergedRegion region = MergedRegion(
        polygon: quad,
        branches: <int>{0},
        score: 1.0,
      );
      // 只带入放大分支图作为识别候选，跳过整图检测。
      final List<BranchOutput> outputs = <BranchOutput>[
        for (final OcrBranch branch in branches)
          if (branch.useForRecognition &&
              BranchPreprocessor.scaleOf(branch) > 1.0)
            BranchOutput(
              branch: branch,
              image: await compute(_prepareBranchImage, (source, branch)),
              scale: BranchPreprocessor.scaleOf(branch),
              boxes: const <BranchBox>[],
            ),
      ];
      return await _recognizeRegion(source, rec, decoder, region, outputs);
    } finally {
      _endRun();
    }
  }

  /// 根据 mode 识别整图；快速模式仅用原图，高精度模式复用多分支流程。
  ///
  /// 每次创建独立微秒统计，阶段总计沿用原计时边界，失败不返回部分诊断。
  Future<OcrResult> run(Uint8List imageBytes, {OcrMode mode = OcrMode.fast}) async {
    _beginRun();
    final OrtSession? det = _detSession;
    final OrtSession? rec = _recSession;
    final CtcDecoder? decoder = _decoder;
    if (det == null || rec == null || decoder == null) {
      throw StateError('OCR models are not loaded');
    }
    final detection = OcrTimingCollector();
    final recognition = OcrTimingCollector();
    _activeTiming = detection;
    try {
      final Stopwatch detWatch = Stopwatch()..start();
      final img.Image source = await _measure(OcrStep.imageDecode,
        () => compute(OcrPreprocessor.decode, imageBytes));
      final List<BranchOutput> branchOutputs = await _detectAllBranches(det, source, branchesFor(mode));
      final List<BranchBox> allBoxes = <BranchBox>[
        for (final BranchOutput output in branchOutputs) ...output.boxes,
      ];
      final List<MergedRegion> ordered = await _measure(OcrStep.merge, () => compute(
        _mergeRegions, (allBoxes, source.width, source.height)));
      detWatch.stop();

      _activeTiming = recognition;
      final Stopwatch recWatch = Stopwatch()..start();
      final List<OcrLine> lines = <OcrLine>[];
      for (final MergedRegion region in ordered) {
        final OcrLine? line =
            await _recognizeRegion(source, rec, decoder, region, branchOutputs);
        if (line != null && !_isNoise(line)) {
          lines.add(line);
        }
      }
      recWatch.stop();

      return OcrResult(
        lines: lines,
        detectMillis: detWatch.elapsedMilliseconds,
        recognizeMillis: recWatch.elapsedMilliseconds,
        diagnostics: OcrDiagnostics(
          accurate: mode == OcrMode.accurate,
          width: source.width,
          height: source.height,
          branchCount: branchOutputs.length,
          regionCount: ordered.length,
          lineCount: lines.length,
          detection: detection.finish(detWatch.elapsedMicroseconds),
          recognition: recognition.finish(recWatch.elapsedMicroseconds),
        ),
      );
    } finally {
      _activeTiming = null;
      _endRun();
    }
  }

  /// 对 activeBranches 中的分支后台预处理，再执行检测并返回分支产物。
  Future<List<BranchOutput>> _detectAllBranches(
    OrtSession session,
    img.Image source,
    List<OcrBranch> activeBranches,
  ) async {
    final List<BranchOutput> outputs = <BranchOutput>[];
    for (int i = 0; i < activeBranches.length; i++) {
      final OcrBranch branch = activeBranches[i];
      final prepared = await _measure(OcrStep.detectionInput,
        () => compute(_prepareBranch, (source, branch)));
      final img.Image branchImage = prepared.$1;
      final double scale = BranchPreprocessor.scaleOf(branch);

      final DetInput detInput = prepared.$2;
      final Float32List prob = await _runDet(session, detInput);
      final List<DbBox> detectedBoxes = await _measure(OcrStep.contours, () => compute(
        _extractBoxes, (prob, detInput.width, detInput.height,
          detInput.scaleX, detInput.scaleY, branch.detThreshOverride),
      ));

      // 分支图上的坐标要换算回原图，后续所有区域都在原图坐标系里统一处理。
      final List<BranchBox> boxes = <BranchBox>[
        for (final DbBox detected in detectedBoxes)
          BranchBox(
            polygon: <ui.Offset>[
              for (final ui.Offset p in detected.polygon)
                ui.Offset(p.dx / scale, p.dy / scale),
            ],
            score: detected.score,
            branchIndex: i,
            branchName: branch.name,
          ),
      ];
      outputs.add(BranchOutput(
        branch: branch,
        image: branchImage,
        scale: scale,
        boxes: boxes,
      ));
    }
    return outputs;
  }

  /// 在多个候选图与裁剪变体之间择优识别一个区域。
  Future<OcrLine?> _recognizeRegion(
    img.Image source,
    OrtSession session,
    CtcDecoder decoder,
    MergedRegion region,
    List<BranchOutput> branchOutputs,
  ) async {
    final ui.Rect bounds = region.bounds;
    final double regionLong = math.max(bounds.width, bounds.height);
    final double regionShort = math.min(bounds.width, bounds.height);

    // 候选变体：原图 + 各可用于识别的分支图。二值化分支只负责找框，
    // 它们的像素丢掉自然灰度分布，喂识别器会大量乱码。
    final List<_RecVariant> variants = <_RecVariant>[
      _RecVariant(image: source, scale: 1.0, label: 'raw'),
      for (final BranchOutput output in branchOutputs)
        if (output.branch.useForRecognition &&
            output.scale > 1.0 &&
            output.image.width > source.width)
          _RecVariant(
            image: output.image,
            scale: output.scale,
            label: output.branch.name,
          ),
    ];

    RecognizeCandidate? best;
    double bestScore = double.negativeInfinity;
    for (final _RecVariant variant in variants) {
      final RecognizeCandidate? candidate = await _recognizeVariant(
        variant,
        region.polygon,
        session,
        decoder,
      );
      if (candidate == null) {
        continue;
      }
      final double score = scoreVariant(candidate, regionLong, regionShort);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    if (best == null) {
      return null;
    }
    return OcrLine(
      text: best.text,
      confidence: best.confidence,
      polygon: region.polygon,
    );
  }

  /// 在某一张候选图上识别一个区域，返回候选结果。
  ///
  /// 在某一张候选图上识别一个区域，返回候选结果。
  Future<RecognizeCandidate?> _recognizeVariant(
    _RecVariant variant,
    List<ui.Offset> polygon,
    OrtSession session,
    CtcDecoder decoder,
  ) async {
    // 框坐标先换算到候选图的坐标系。
    final List<ui.Offset> quad = <ui.Offset>[
      for (final ui.Offset p in polygon)
        ui.Offset(
          (p.dx * variant.scale).clamp(0.0, variant.image.width - 1.0),
          (p.dy * variant.scale).clamp(0.0, variant.image.height - 1.0),
        ),
    ];
    final DecodedText? decoded =
        await _runRecognize(variant.image, quad, session, decoder);
    return decoded == null ? null : _toCandidate(decoded, variant);
  }

  /// 对 image 中的 quad 后台构造输入和解码，原生推理保留在当前 isolate。
  Future<DecodedText?> _runRecognize(
    img.Image image,
    List<ui.Offset> quad,
    OrtSession session,
    CtcDecoder decoder,
  ) async {
    final int width = OcrPreprocessor.recOutputWidth(quad);
    final Float32List data = await _measure(OcrStep.recognitionInput,
      () => compute(_prepareRecognition, (image, quad)));
    if (data.isEmpty) {
      return null;
    }
    final List<dynamic> raw = await _runSession(
      session,
      data,
      <int>[1, 3, OcrPreprocessor.recInputHeight, width],
    );
    final int classCount = decoder.dictionarySize + 2;
    if (raw.length % classCount != 0) {
      throw StateError(
        'Unexpected recognition output size ${raw.length} '
        'for $classCount classes',
      );
    }
    // 保留明细项并明确记为零：识别输出直接解码，未执行独立数值转换。
    _activeTiming?.record(OcrStep.outputConvert, 0);
    final DecodedText decoded =
        await _measure(OcrStep.ctc,
          () => compute(_decodeRecognition, (decoder, raw, classCount)));
    return decoded.text.isEmpty ? null : decoded;
  }

  static RecognizeCandidate _toCandidate(DecodedText decoded, _RecVariant variant) {
    return RecognizeCandidate(
      text: decoded.text,
      confidence: decoded.confidence,
      label: variant.label,
      scale: variant.scale,
      enhanced: false,
    );
  }

  /// 后台合并检测框并扩展识别窗，参数为候选框和原图尺寸。
  static List<MergedRegion> _mergeRegions((List<BranchBox>, int, int) input) {
    final regions = BoxMerger.stitchSameLine(
      BoxMerger.merge(input.$1, mergeConfig), mergeConfig);
    for (final region in regions) {
      region.polygon = BoxMerger.buildRecognitionWindow(
        region, mergeConfig, input.$2, input.$3);
    }
    return _sortReadingOrder(regions);
  }

  /// 按阅读顺序排序：先按行（纵向中心）分桶，桶内按 x 升序。
  ///
  /// 行容差取最大字高的一半，避免轻微倾斜把同一行拆成两行。
  static List<MergedRegion> _sortReadingOrder(List<MergedRegion> regions) {
    if (regions.length < 2) {
      return regions;
    }
    double maxHeight = 1.0;
    for (final MergedRegion region in regions) {
      maxHeight = math.max(maxHeight, region.bounds.height);
    }
    final double tolerance = math.max(6.0, maxHeight * 0.5);

    final List<MergedRegion> byTop = List<MergedRegion>.of(regions)
      ..sort((MergedRegion a, MergedRegion b) =>
          a.bounds.center.dy.compareTo(b.bounds.center.dy));

    final List<List<MergedRegion>> rows = <List<MergedRegion>>[];
    for (final MergedRegion region in byTop) {
      if (rows.isNotEmpty) {
        final double rowCenter = rows.last.first.bounds.center.dy;
        if ((region.bounds.center.dy - rowCenter).abs() <= tolerance) {
          rows.last.add(region);
          continue;
        }
      }
      rows.add(<MergedRegion>[region]);
    }

    final List<MergedRegion> sorted = <MergedRegion>[];
    for (final List<MergedRegion> row in rows) {
      row.sort((MergedRegion a, MergedRegion b) =>
          a.bounds.left.compareTo(b.bounds.left));
      sorted.addAll(row);
    }
    return sorted;
  }

  /// 执行检测模型，返回扁平化的概率图数据。
  Future<Float32List> _runDet(OrtSession session, DetInput input) async {
    final raw = await _runSession(
      session,
      input.data,
      <int>[1, 3, input.height, input.width],
    );
    // 检测后处理需要 Float32 数据；识别输出则直接交给 CTC，跳过转换。
    return _measure(OcrStep.outputConvert, () => compute(_flattenOutput, raw));
  }

  /// 测量完整异步 action，包含通信、调度及等待；调用之间不可嵌套。
  Future<T> _measure<T>(OcrStep step, Future<T> Function() action) async {
    final collector = _activeTiming;
    if (collector == null) return action();
    final watch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      watch.stop();
      collector.record(step, watch.elapsedMicroseconds);
    }
  }

  /// 提交推理并返回插件原始列表，不创建中间数值数组。
  /// 分别测量输入创建、插件推理、输出传递和资源释放。
  ///
  /// 输入与输出张量都持有原生内存，必须显式释放，否则连续识别会持续泄漏。
  Future<List<dynamic>> _runSession(
    OrtSession session,
    Float32List data,
    List<int> shape,
  ) async {
    final OrtValue input = await _measure(OcrStep.inputTensor,
      () => OrtValue.fromList(data, shape));
    Map<String, OrtValue>? outputs;
    try {
      outputs = await _measure(OcrStep.inference,
        () => session.run(<String, OrtValue>{session.inputNames.single: input}));
      final OrtValue? value = outputs![session.outputNames.first];
      if (value == null) {
        throw StateError('Session output "$outputName" is missing');
      }
      final List<dynamic> raw = await _measure(OcrStep.outputRead,
        value.asFlattenedList);
      _activeTiming?.outputElements += raw.length;
      return raw;
    } finally {
      await _measure(OcrStep.release, () async {
        await input.dispose();
        if (outputs != null) {
          for (final OrtValue value in outputs.values) {
            await value.dispose();
          }
        }
      });
    }
  }
}

/// 一个检测分支的产物：分支图、缩放倍数与检出框。
class BranchOutput {
  const BranchOutput({
    required this.branch,
    required this.image,
    required this.scale,
    required this.boxes,
  });

  final OcrBranch branch;
  final img.Image image;
  final double scale;
  final List<BranchBox> boxes;
}

/// 识别候选图及其相对原图的缩放倍数。
class _RecVariant {
  const _RecVariant({
    required this.image,
    required this.scale,
    required this.label,
  });

  final img.Image image;
  final double scale;
  final String label;
}

/// 后台生成分支图和检测输入，参数仅包含 Dart 数据。
(img.Image, DetInput) _prepareBranch((img.Image, OcrBranch) input) {
  final image = BranchPreprocessor.apply(input.$1, input.$2);
  return (image, OcrPreprocessor.buildDetInput(image));
}

/// 后台提取轮廓，参数为概率图、尺寸、比例和阈值。
List<DbBox> _extractBoxes((Float32List, int, int, double, double, double?) input) {
  return DbPostprocessor.extractScoredBoxes(input.$1, input.$2, input.$3,
    scaleX: input.$4, scaleY: input.$5, threshOverride: input.$6);
}

/// 后台透视裁剪与归一化，输入为图片和四边形。
Float32List _prepareRecognition((img.Image, List<ui.Offset>) input) =>
    OcrPreprocessor.buildRecInput(input.$1, input.$2);

/// 后台直接解码插件数值列表，cast 仅创建视图，不复制全部概率值。
/// 输出已由浮点模型生成，数值列表与原 Float32 输出表示相同概率。
DecodedText _decodeRecognition((CtcDecoder, List<dynamic>, int) input) =>
    input.$1.decode(input.$2.cast<num>(), input.$2.length ~/ input.$3, input.$3);

/// 检测输出只分配一次定长数组，避免先创建同等大小的装箱 double 列表。
Float32List _flattenOutput(List<dynamic> raw) {
  final result = Float32List(raw.length);
  for (int i = 0; i < raw.length; i++) {
    final value = raw[i];
    result[i] = value is num ? value.toDouble() : 0;
  }
  return result;
}


/// 后台只生成候选图，单区域识别不需要构造整图检测输入。
img.Image _prepareBranchImage((img.Image, OcrBranch) input) =>
    BranchPreprocessor.apply(input.$1, input.$2);
