import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ocr/ocr_diagnostics.dart';

/// 独立的诊断折叠面板；快照变化时收起，避免混淆不同图片的测量。
class OcrTimingDetails extends StatefulWidget {
  const OcrTimingDetails({super.key, required this.diagnostics});

  final OcrDiagnostics? diagnostics;

  @override
  State<OcrTimingDetails> createState() => _OcrTimingDetailsState();
}

class _OcrTimingDetailsState extends State<OcrTimingDetails> {
  /// 内容高度限制，避免明细挤占整页的图片预览。
  static const double _maxDetailHeight = 260;
  static const double _screenHeightFraction = 0.3;
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant OcrTimingDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.diagnostics, widget.diagnostics)) {
      _expanded = false;
    }
  }

  /// 将微秒转换为适合阅读的单位，小步骤保留小数避免显示为零。
  String _duration(num micros) => micros >= Duration.microsecondsPerSecond
      ? '${(micros / Duration.microsecondsPerSecond).toStringAsFixed(2)} s'
      : '${(micros / Duration.microsecondsPerMillisecond).toStringAsFixed(2)} ms';

  /// 复制当前 data 快照的完整统计，收起状态也可使用，不包含识别正文。
  Future<void> _copyDetails(OcrDiagnostics data) async {
    final text = StringBuffer()
      ..writeln('OCR Timing details')
      ..writeln('Mode：${data.accurate ? 'Accurate' : 'Fast'}')
      ..writeln('Image：${data.width} × ${data.height}')
      ..writeln('Branches：${data.branchCount}；Regions：${data.regionCount}；Lines：${data.lineCount}')
      ..writeln('Inference calls：Detection ${data.detection.inferenceCount} / Recognition ${data.recognition.inferenceCount}')
      ..writeln('Recognition output elements：${data.recognition.outputElements}')
      ..writeln('Recognition inference：Average ${_duration(data.recognition.averageInferenceMicros)} / '
          'Maximum ${_duration(data.recognition.maxInferenceMicros)}');
    for (final entry in <String, OcrStageTiming>{
      'Detection stage': data.detection, 'Recognition stage': data.recognition,
    }.entries) {
      final stage = entry.value;
      text
        ..writeln()
        ..writeln('${entry.key}：${_duration(stage.totalMicros)}')
        ..writeln('Step | Duration | Stage share');
      for (final step in OcrStep.values) {
        if (!stage.steps.containsKey(step)) continue;
        final micros = stage.steps[step]!;
        final percent = stage.totalMicros == 0 ? 0.0 : micros * 100 / stage.totalMicros;
        text.writeln('${step.label} | ${_duration(micros)} | ${percent.toStringAsFixed(1)}%');
      }
    }
    text
      ..writeln()
      ..writeln('Background processing includes scheduling; inference includes plugin communication;'
          'Output reading includes native-to-Dart transfer.');
    try {
      await Clipboard.setData(ClipboardData(text: text.toString()));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Timing details copied')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Copy failed：$error')));
    }
  }

  /// 按流水线顺序绘制 stage，各步骤占比使用该阶段微秒总计。
  Widget _stage(String title, OcrStageTiming stage, List<OcrStep> order) {
    final maxMicros = stage.steps.values.fold<int>(
      0, (largest, value) => math.max(largest, value));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('$title · ${_duration(stage.totalMicros)}',
            style: Theme.of(context).textTheme.titleSmall),
        ),
        const Row(children: <Widget>[
          Expanded(flex: 3, child: Text('Step')),
          Expanded(child: Text('Duration', textAlign: TextAlign.right)),
          Expanded(child: Text('Stage share', textAlign: TextAlign.right)),
        ]),
        for (final step in order)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: DefaultTextStyle.merge(
              style: TextStyle(
                fontWeight: maxMicros > 0 && stage.steps[step] == maxMicros
                    ? FontWeight.bold : FontWeight.normal,
                color: maxMicros > 0 && stage.steps[step] == maxMicros
                    ? Theme.of(context).colorScheme.primary : null,
              ),
              child: Row(children: <Widget>[
                Expanded(flex: 3, child: Text(step.label)),
                Expanded(child: Text(_duration(stage.steps[step] ?? 0),
                  textAlign: TextAlign.right)),
                Expanded(child: Text(stage.totalMicros == 0 ? '0.0%'
                  : '${((stage.steps[step] ?? 0) * 100 / stage.totalMicros).toStringAsFixed(1)}%',
                  textAlign: TextAlign.right)),
              ]),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.diagnostics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Timing details'),
          subtitle: data == null ? const Text('Available after recognition') : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: 'Copy timing details',
                onPressed: data == null ? null : () => _copyDetails(data),
                icon: const Icon(Icons.copy),
              ),
              Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            ],
          ),
          onTap: data == null ? null : () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded && data != null)
          SizedBox(
            height: math.min(_maxDetailHeight,
              MediaQuery.sizeOf(context).height * _screenHeightFraction),
            child: SingleChildScrollView(
              key: const ValueKey<String>('ocr-timing-scroll'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('${data.accurate ? 'Accurate' : 'Fast'} · '
                    '${data.width} × ${data.height} · Branches ${data.branchCount} · '
                    'Regions ${data.regionCount} · Lines ${data.lineCount}'),
                  Text('Inference calls：Detection ${data.detection.inferenceCount} / '
                    'Recognition ${data.recognition.inferenceCount}'),
                  Text('Recognition output elements：${data.recognition.outputElements} · '
                    'Recognition inference：Average ${_duration(data.recognition.averageInferenceMicros)} / '
                    'Maximum ${_duration(data.recognition.maxInferenceMicros)}'),
                  const Text('Background processing includes scheduling;'
                    'Inference includes plugin communication;Output reading includes native-to-Dart transfer.'),
                  _stage('Detection stage', data.detection, const <OcrStep>[
                    OcrStep.imageDecode, OcrStep.detectionInput, OcrStep.inputTensor,
                    OcrStep.inference, OcrStep.outputRead, OcrStep.outputConvert,
                    OcrStep.contours, OcrStep.merge, OcrStep.release, OcrStep.other,
                  ]),
                  _stage('Recognition stage', data.recognition, const <OcrStep>[
                    OcrStep.recognitionInput, OcrStep.inputTensor, OcrStep.inference,
                    OcrStep.outputRead, OcrStep.outputConvert, OcrStep.ctc,
                    OcrStep.release, OcrStep.other,
                  ]),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
