/// 流水线步骤；顺序用于明细展示，名称避免将插件调用误称为纯推理。
enum OcrStep {
  imageDecode('Image decode'),
  detectionInput('Branch preprocessing'),
  recognitionInput('Crop and normalize'),
  inputTensor('Input tensor'),
  inference('Inference (including messaging)'),
  outputRead('Output read'),
  outputConvert('Output conversion'),
  contours('Contours'),
  merge('Merge and sort'),
  ctc('CTC decode'),
  release('Tensor release'),
  other('Scheduling');

  const OcrStep(this.label);
  final String label;
}

/// 一个阶段的不可变计时快照；仅保存微秒数与计数。
class OcrStageTiming {
  /// 从累计值创建快照，steps 会复制为只读映射。
  OcrStageTiming({
    required this.totalMicros,
    required Map<OcrStep, int> steps,
    required this.inferenceCount,
    required this.maxInferenceMicros,
    required this.outputElements,
  }) : steps = Map<OcrStep, int>.unmodifiable(steps);

  final int totalMicros;
  final Map<OcrStep, int> steps;
  final int inferenceCount;
  final int maxInferenceMicros;
  final int outputElements;

  /// 没有推理调用时平均耗时为零，避免除零。
  double get averageInferenceMicros => inferenceCount == 0
      ? 0
      : (steps[OcrStep.inference] ?? 0) / inferenceCount;
}

/// 单次 run 的诊断信息，不保存图片、模型输出或原生资源。
class OcrDiagnostics {
  const OcrDiagnostics({
    required this.accurate,
    required this.width,
    required this.height,
    required this.branchCount,
    required this.regionCount,
    required this.lineCount,
    required this.detection,
    required this.recognition,
  });

  final bool accurate;
  final int width;
  final int height;
  final int branchCount;
  final int regionCount;
  final int lineCount;
  final OcrStageTiming detection;
  final OcrStageTiming recognition;
}

/// 单阶段计时累加器，每次 run 分别创建检测和识别实例。
class OcrTimingCollector {
  final Map<OcrStep, int> _steps = <OcrStep, int>{};
  int _inferenceCount = 0;
  int _maxInferenceMicros = 0;
  int outputElements = 0;

  /// 累计一个非嵌套步骤的微秒值；推理步骤同时记录次数与最大值。
  void record(OcrStep step, int micros) {
    _steps[step] = (_steps[step] ?? 0) + micros;
    if (step == OcrStep.inference) {
      _inferenceCount++;
      if (micros > _maxInferenceMicros) _maxInferenceMicros = micros;
    }
  }

  /// 以原阶段计时器为父级，将未覆盖耗时归入其他调度。
  OcrStageTiming finish(int totalMicros) {
    final measured = _steps.values.fold<int>(0, (sum, value) => sum + value);
    if (measured > totalMicros) {
      throw StateError('步骤计时超过阶段总计，可能存在嵌套计时');
    }
    return OcrStageTiming(
      totalMicros: totalMicros,
      steps: <OcrStep, int>{..._steps, OcrStep.other: totalMicros - measured},
      inferenceCount: _inferenceCount,
      maxInferenceMicros: _maxInferenceMicros,
      outputElements: outputElements,
    );
  }
}
