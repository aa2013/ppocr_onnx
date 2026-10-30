import 'dart:ui_web' as ui_web;

/// 将 Flutter asset key 转为实际资源 URL，沿用引擎的 assetBase 和编码规则。
String resolveModelUrl(String assetKey) => ui_web.assetManager.getAssetUrl(assetKey);
