import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'model_paths.dart';
import 'model_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'ocr_engine.dart';
import 'ocr_result.dart';

/// 在独立 isolate 创建与释放会话；Web 使用同一 API 在当前事件循环执行。
class OcrWorker {
  OcrWorker({required this.modelPath});
  final String modelPath;
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _events;
  Future<int>? _starting;
  Future<void>? _closing;
  Completer<SendPort>? _ready;
  OcrEngine? _webEngine;
  int _sequence = 0;
  int _loadMillis = 0;
  final Map<int, Completer<Object?>> _pending = {};
  final Set<Future<OcrResult>> _runs = {};

  /// 启动并加载模型；合并并发启动，返回加载耗时。
  Future<int> start() {
    if (_closing != null) return Future.error(StateError('Worker is disposing'));
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  /// 原生会话只存在于 worker；启动失败后清理端口以允许重试。
  Future<int> _start() async {
    if (_commands != null || _webEngine?.isReady == true) return _loadMillis;
    if (kIsWeb) {
      _webEngine ??= OcrEngine(modelPath: modelPath);
      return _loadMillis = await _webEngine!.load();
    }
    final token = RootIsolateToken.instance;
    if (token == null) throw StateError('Start OcrWorker from the root isolate');
    Directory? temporary;
    String directory = modelPath;
    if (!File(modelPath).isAbsolute) {
      temporary = await Directory.systemTemp.createTemp('ppocr_worker_');
      try {
        final paths = OcrModelPaths(modelPath);
        for (final entry in <String, String>{
          OcrModelPaths.detFilename: paths.det,
          OcrModelPaths.recFilename: paths.rec,
          OcrModelPaths.dictFilename: paths.dict,
        }.entries) {
          final bytes = await readModelBytes(entry.value);
          await File('${temporary.path}/${entry.key}').writeAsBytes(
            bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
        }
        directory = temporary.path;
      } catch (_) {
        await temporary.delete(recursive: true);
        rethrow;
      }
    }
    _ready = Completer<SendPort>();
    _events = ReceivePort()..listen(_onEvent);
    try {
      _isolate = await Isolate.spawn(_entry, (_events!.sendPort, directory, token),
        onError: _events!.sendPort, onExit: _events!.sendPort, errorsAreFatal: true);
      _commands = await _ready!.future;
      return _loadMillis = await _request('load') as int;
    } catch (_) {
      _cleanup();
      rethrow;
    } finally {
      await temporary?.delete(recursive: true);
    }
  }

  /// 返回完整结果和诊断快照；请求按接收顺序串行处理。
  Future<OcrResult> run(Uint8List bytes, {OcrMode mode = OcrMode.fast}) {
    if (_closing != null) return Future.error(StateError('Worker is disposing'));
    final future = _run(bytes, mode);
    _runs.add(future);
    return future.whenComplete(() => _runs.remove(future));
  }

  /// 启动完成后提交图片；dispose 会等待已经接收的调用。
  Future<OcrResult> _run(Uint8List bytes, OcrMode mode) async {
    await start();
    if (kIsWeb) return _webEngine!.run(bytes, mode: mode);
    return await _request('run', (bytes, mode)) as OcrResult;
  }

  /// 等待已提交请求结束后释放；完成后可以再次 start。
  Future<void> dispose() => _closing ??= _dispose().whenComplete(() => _closing = null);

  /// 加载失败也必须释放端口与 isolate。
  Future<void> _dispose() async {
    try {
      try { await _starting; } catch (_) {}
      for (final run in _runs.toList()) {
        try { await run; } catch (_) {}
      }
      if (kIsWeb) {
        await _webEngine?.dispose();
        _webEngine = null;
      } else if (_commands != null) {
        await _request('dispose');
      }
    } finally {
      _cleanup();
    }
  }

  /// 发送编号请求，响应只完成对应的调用。
  Future<Object?> _request(String operation, [Object? payload]) {
    final id = _sequence++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands!.send((id, operation, payload));
    return completer.future;
  }

  /// 接收握手、结果和异常退出；异常退出不能让调用方永久等待。
  void _onEvent(Object? event) {
    if (event is SendPort) {
      _ready!.complete(event);
    } else if (event is (int, bool, Object?)) {
      final completer = _pending.remove(event.$1);
      if (event.$2) {
        completer?.complete(event.$3);
      } else {
        completer?.completeError(StateError(event.$3.toString()));
      }
    } else {
      final error = StateError('OCR worker exited: $event');
      if (_ready?.isCompleted == false) _ready!.completeError(error);
      for (final pending in _pending.values) { pending.completeError(error); }
      _pending.clear();
      _cleanup();
    }
  }

  /// 只回收本实例持有的资源，不影响其他 worker。
  void _cleanup() {
    _isolate?.kill(priority: Isolate.immediate);
    _events?.close();
    _isolate = null;
    _events = null;
    _commands = null;
  }

  /// 原生通信注册完成后才创建引擎；结果仅含 Dart 数据。
  static Future<void> _entry((SendPort, String, RootIsolateToken) args) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(args.$3);
    final engine = OcrEngine(modelPath: args.$2);
    final commands = ReceivePort();
    args.$1.send(commands.sendPort);
    await for (final dynamic message in commands) {
      final (int id, String operation, Object? payload) = message;
      try {
        Object? result;
        switch (operation) {
          case 'load':
            result = await engine.load();
          case 'run':
            final input = payload as (Uint8List, OcrMode);
            result = await engine.run(input.$1, mode: input.$2);
          case 'dispose': await engine.dispose();
          default: throw StateError('Unknown OCR operation: $operation');
        }
        args.$1.send((id, true, result));
        if (operation == 'dispose') commands.close();
      } catch (error) {
        args.$1.send((id, false, '$error'));
      }
    }
  }
}
