import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ppocr_onnx/ppocr_onnx.dart';

void main() => runApp(const PpOcrExampleApp());

class PpOcrExampleApp extends StatelessWidget {
  const PpOcrExampleApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PP-OCR ONNX',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue), useMaterial3: true),
        home: const _Page(),
      );
}

class _Page extends StatefulWidget {
  const _Page();
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  String _modelPath = 'assets/models';
  String? _imagePath;
  Uint8List? _bytes;
  ui.Size? _size;
  OcrResult? _result;
  OcrMode _mode = OcrMode.fast;
  int? _hovered;
  int? _loadMillis;
  bool _busy = false;
  late OcrWorker _engine;

  @override
  void initState() {
    super.initState();
    _engine = OcrWorker(modelPath: _modelPath);
  }

  /// 切换目录前等待旧 worker 释放；文件选择期间禁用识别。
  Future<void> _pickModel() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose model directory');
      if (path == null || !mounted) return;
      await _engine.dispose();
      if (!mounted) return;
      setState(() {
        _modelPath = path;
        _engine = OcrWorker(modelPath: path);
        _result = null;
        _hovered = null;
        _loadMillis = null;
      });
    } catch (error) {
      _message('Cannot open model directory: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 从选择器读取图片字节，兼容浏览器而不依赖本地文件路径。
  Future<void> _pickImage() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFiles(type: FileType.image);
      if (picked.isEmpty || !mounted) return;
      final file = picked.first;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      late ui.Size size;
      try {
        final frame = await codec.getNextFrame();
        try {
          size = ui.Size(frame.image.width.toDouble(), frame.image.height.toDouble());
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      if (!mounted) return;
      setState(() {
        _imagePath = file.path ?? file.name;
        _bytes = bytes;
        _size = size;
        _result = null;
        _hovered = null;
      });
    } catch (error) {
      _message('Cannot open image: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 每次识别清空旧结果，耗时来自后台返回的完整快照。
  Future<void> _run() async {
    if (_bytes == null || _busy) return;
    setState(() { _busy = true; _result = null; _hovered = null; });
    try {
      final int loaded = await _engine.start();
      final OcrResult result = await _engine.run(_bytes!, mode: _mode);
      if (mounted) setState(() { _loadMillis = loaded > 0 ? loaded : _loadMillis; _result = result; });
    } catch (error) { if (mounted) _message('OCR failed: $error'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  /// 页面关闭后忽略迟到的异步提示。
  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    unawaited(_engine.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('PP-OCR ONNX')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(),
            _pathRow(_modelPath, 'Copy model path'),
            _pathRow(_imagePath, 'Copy image path'),
            const SizedBox(height: 8),
            SegmentedButton<OcrMode>(
              segments: const [
                ButtonSegment(value: OcrMode.fast, label: Text('Fast')),
                ButtonSegment(value: OcrMode.accurate, label: Text('Accurate')),
              ],
              selected: {_mode},
              onSelectionChanged: _busy ? null : (value) => setState(() {
                _mode = value.single;
                _result = null;
                _hovered = null;
              }),
            ),
            const SizedBox(height: 12),
            Expanded(child: LayoutBuilder(builder: (context, constraints) {
              final panels = <Widget>[
                Expanded(flex: 3, child: _preview()),
                const SizedBox(width: 12, height: 12),
                Expanded(flex: 2, child: _results(result)),
              ];
              return Flex(
                direction: constraints.maxWidth < _compactWidth
                    ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: panels,
              );
            })),
            OcrTimingDetails(diagnostics: result?.diagnostics),
            Wrap(spacing: 16, children: [
              Text('Load: ${_loadMillis ?? '—'} ms'),
              Text('Detect: ${result?.detectMillis ?? '—'} ms'),
              Text('Recognize: ${result?.recognizeMillis ?? '—'} ms'),
              Text('Total: ${result?.totalMillis ?? '—'} ms'),
            ]),
          ],
        ),
      ),
    );
  }

  /// 紧凑窗口改为上下布局，避免手机上横向面板挤压文字。
  static const double _compactWidth = 650;

  /// 操作按钮可换行；目录选择仅适用于原生文件系统。
  Widget _toolbar() => Wrap(spacing: 8, runSpacing: 8, children: [
    FilledButton.icon(
      onPressed: _busy || kIsWeb ? null : _pickModel,
      icon: const Icon(Icons.folder_open),
      label: const Text('Model directory'),
    ),
    FilledButton.icon(
      onPressed: _busy ? null : _pickImage,
      icon: const Icon(Icons.image),
      label: const Text('Image'),
    ),
    FilledButton.icon(
      onPressed: _bytes == null || _busy ? null : _run,
      icon: const Icon(Icons.play_arrow),
      label: Text(_busy ? 'Running…' : 'Run OCR'),
    ),
    TextButton(
      onPressed: _result == null ? null
          : () => Clipboard.setData(ClipboardData(text: _result!.fullText)),
      child: const Text('Copy text'),
    ),
  ]);

  /// 路径显示截断，复制仍保留 path 的完整内容。
  Widget _pathRow(String? path, String tooltip) => Row(children: [
    Expanded(child: Text(path ?? 'No image selected',
      maxLines: 1, overflow: TextOverflow.ellipsis)),
    IconButton(
      tooltip: tooltip,
      onPressed: path == null ? null
          : () => Clipboard.setData(ClipboardData(text: path)),
      icon: const Icon(Icons.copy),
    ),
  ]);

  /// 图片与结果列表共享高亮索引，预览组件只负责图片坐标映射。
  Widget _preview() => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    child: _bytes == null || _size == null
        ? const Center(child: Text('Choose an image to preview'))
        : OcrOverlayViewer(
            image: MemoryImage(_bytes!),
            imageSize: _size!,
            lines: _result?.lines ?? const [],
            hoveredIndex: _hovered,
            onHovered: (value) => setState(() => _hovered = value),
            onSelected: (value) => setState(() => _hovered = value),
          ),
  );

  /// 列表悬浮与点击更新预览中的同一高亮索引。
  Widget _results(OcrResult? result) => Card(
    child: result == null
        ? const Center(child: Text('No results'))
        : ListView.builder(
            itemCount: result.lines.length,
            itemBuilder: (context, index) {
              final line = result.lines[index];
              return MouseRegion(
                onEnter: (_) => setState(() => _hovered = index),
                onExit: (_) => setState(() => _hovered = null),
                child: ListTile(
                  selected: index == _hovered,
                  selectedTileColor: Theme.of(context).colorScheme.secondaryContainer,
                  title: SelectableText(line.text),
                  subtitle: Text('Confidence ${(line.confidence * 100).toStringAsFixed(1)}% • ${line.bounds}'),
                  onTap: () => setState(() => _hovered = index),
                ),
              );
            },
          ),
  );
}
