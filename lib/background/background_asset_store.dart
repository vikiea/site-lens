import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'dart:io';

class BackgroundAssetStore {
  BackgroundAssetStore({Future<Directory> Function()? rootProvider})
    : _rootProvider = rootProvider ?? _defaultRoot;

  static const maxBytes = 16 * 1024 * 1024;
  static const maxDimension = 4096;
  static const maxPixels = 16 * 1024 * 1024;
  static final _assetId = RegExp(r'^[a-f0-9]{64}\.(?:png|jpe?g|webp)$');
  final Future<Directory> Function() _rootProvider;

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'site_lens_backgrounds'));
  }

  Future<Directory> _root() async {
    final root = await _rootProvider();
    await root.create(recursive: true);
    return root;
  }

  Future<String> importBytes(Uint8List bytes, String extension) async {
    final normalized = await validateBytes(bytes, extension);
    final digest = sha256.convert(bytes).toString();
    final assetId = '$digest.$normalized';
    final root = await _root();
    final target = File(p.join(root.path, assetId));
    if (await target.exists() && await target.length() == bytes.length) {
      return assetId;
    }
    final temporary = File('${target.path}.part');
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      if (await target.exists()) await target.delete();
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    return assetId;
  }

  static Future<String> validateBytes(Uint8List bytes, String extension) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('背景图片大小无效');
    }
    final normalized = _normalizeExtension(extension);
    _validateSignature(bytes, normalized);
    final codec = await _decode(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        final width = frame.image.width;
        final height = frame.image.height;
        if (width > maxDimension ||
            height > maxDimension ||
            width * height > maxPixels) {
          throw const FormatException('背景图片解码尺寸过大');
        }
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
    return normalized;
  }

  static Future<ui.Codec> _decode(Uint8List bytes) async {
    try {
      return await ui.instantiateImageCodec(bytes);
    } catch (_) {
      throw const FormatException('背景图片无法解码');
    }
  }

  Future<File?> fileFor(String? assetId) async {
    if (assetId == null || !_assetId.hasMatch(assetId)) return null;
    final root = await _root();
    final file = File(p.join(root.path, assetId));
    return await file.exists() ? file : null;
  }

  Future<void> delete(String? assetId) async {
    final file = await fileFor(assetId);
    if (file == null) return;
    await file.delete();
  }

  Future<void> cleanupUnused(Iterable<String> liveAssetIds) async {
    final live = liveAssetIds.toSet();
    final root = await _root();
    await for (final entity in root.list()) {
      if (entity is! File || !_assetId.hasMatch(p.basename(entity.path))) {
        continue;
      }
      if (!live.contains(p.basename(entity.path))) {
        await entity.delete();
      }
    }
  }

  static String _normalizeExtension(String extension) {
    final normalized = extension.toLowerCase().replaceFirst('.', '');
    if (!{'png', 'jpg', 'jpeg', 'webp'}.contains(normalized)) {
      throw const FormatException('背景图片格式不支持');
    }
    return normalized;
  }

  static void _validateSignature(Uint8List bytes, String extension) {
    final valid = switch (extension) {
      'png' =>
        bytes.length >= 8 &&
            bytes[0] == 0x89 &&
            bytes[1] == 0x50 &&
            bytes[2] == 0x4e &&
            bytes[3] == 0x47 &&
            bytes[4] == 0x0d &&
            bytes[5] == 0x0a &&
            bytes[6] == 0x1a &&
            bytes[7] == 0x0a,
      'jpg' =>
        bytes.length >= 3 &&
            bytes[0] == 0xff &&
            bytes[1] == 0xd8 &&
            bytes[2] == 0xff,
      'jpeg' =>
        bytes.length >= 3 &&
            bytes[0] == 0xff &&
            bytes[1] == 0xd8 &&
            bytes[2] == 0xff,
      'webp' =>
        bytes.length >= 12 &&
            String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
            String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP',
      _ => false,
    };
    if (!valid) throw const FormatException('背景图片内容与扩展名不匹配');
  }
}
