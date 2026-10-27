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
      final existingDigest = await sha256.bind(target.openRead()).first;
      if (existingDigest.toString() == digest) return assetId;
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
    final dimensions = _encodedDimensions(bytes, normalized);
    if (dimensions.width > maxDimension ||
        dimensions.height > maxDimension ||
        dimensions.width * dimensions.height > maxPixels) {
      throw const FormatException('背景图片解码尺寸过大');
    }
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

  static ({int width, int height}) _encodedDimensions(
    Uint8List bytes,
    String extension,
  ) {
    switch (extension) {
      case 'png':
        if (bytes.length < 24) throw const FormatException('背景图片头无效');
        return (width: _u32be(bytes, 16), height: _u32be(bytes, 20));
      case 'jpg':
      case 'jpeg':
        return _jpegDimensions(bytes);
      case 'webp':
        return _webpDimensions(bytes);
      default:
        throw const FormatException('背景图片头无效');
    }
  }

  static ({int width, int height}) _jpegDimensions(Uint8List bytes) {
    var offset = 2;
    while (offset + 3 < bytes.length) {
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) break;
      final marker = bytes[offset++];
      if (marker == 0xd8 || marker == 0xd9 || marker == 0x01) continue;
      if (marker == 0xda) break;
      if (offset + 1 >= bytes.length) break;
      final length = _u16be(bytes, offset);
      if (length < 2 || offset + length > bytes.length) break;
      final sof =
          (marker >= 0xc0 && marker <= 0xc3) ||
          (marker >= 0xc5 && marker <= 0xc7) ||
          (marker >= 0xc9 && marker <= 0xcb) ||
          (marker >= 0xcd && marker <= 0xcf);
      if (sof && length >= 7) {
        return (
          width: _u16be(bytes, offset + 5),
          height: _u16be(bytes, offset + 3),
        );
      }
      offset += length;
    }
    throw const FormatException('背景图片头无效');
  }

  static ({int width, int height}) _webpDimensions(Uint8List bytes) {
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final tag = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = _u32le(bytes, offset + 4);
      final data = offset + 8;
      if (data + size > bytes.length) break;
      if (tag == 'VP8X' && size >= 10) {
        return (
          width: 1 + _u24le(bytes, data + 4),
          height: 1 + _u24le(bytes, data + 7),
        );
      }
      if (tag == 'VP8 ' &&
          size >= 10 &&
          bytes[data + 3] == 0x9d &&
          bytes[data + 4] == 0x01 &&
          bytes[data + 5] == 0x2a) {
        return (
          width: _u16le(bytes, data + 6) & 0x3fff,
          height: _u16le(bytes, data + 8) & 0x3fff,
        );
      }
      if (tag == 'VP8L' && size >= 5 && bytes[data] == 0x2f) {
        final b1 = bytes[data + 1];
        final b2 = bytes[data + 2];
        final b3 = bytes[data + 3];
        final b4 = bytes[data + 4];
        return (
          width: 1 + (b1 | ((b2 & 0x3f) << 8)),
          height: 1 + ((b2 >> 6) | (b3 << 2) | ((b4 & 0x0f) << 10)),
        );
      }
      offset = data + size + (size.isOdd ? 1 : 0);
    }
    throw const FormatException('背景图片头无效');
  }

  static int _u16be(Uint8List bytes, int offset) =>
      (bytes[offset] << 8) | bytes[offset + 1];

  static int _u32be(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _u16le(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8);

  static int _u24le(Uint8List bytes, int offset) =>
      bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

  static int _u32le(Uint8List bytes, int offset) =>
      bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);

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
