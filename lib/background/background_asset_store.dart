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
      final existingDigest = sha256
          .convert(await target.readAsBytes())
          .toString();
      if (existingDigest == digest) return assetId;
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
    final headerDimensions = _readHeaderDimensions(bytes, normalized);
    if (headerDimensions != null) {
      _validateDimensions(headerDimensions.width, headerDimensions.height);
    }
    final codec = await _decode(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        _validateDimensions(frame.image.width, frame.image.height);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
    return normalized;
  }

  static ({int width, int height})? _readHeaderDimensions(
    Uint8List bytes,
    String extension,
  ) {
    return switch (extension) {
      'png' => _readPngDimensions(bytes),
      'jpg' || 'jpeg' => _readJpegDimensions(bytes),
      'webp' => _readWebpDimensions(bytes),
      _ => null,
    };
  }

  static void _validateDimensions(int width, int height) {
    if (width > maxDimension ||
        height > maxDimension ||
        width * height > maxPixels) {
      throw const FormatException('背景图片解码尺寸过大');
    }
  }

  static ({int width, int height})? _readPngDimensions(Uint8List bytes) {
    if (bytes.length < 24 ||
        !_matches(bytes, 12, const [0x49, 0x48, 0x44, 0x52])) {
      return null;
    }
    return (width: _u32be(bytes, 16), height: _u32be(bytes, 20));
  }

  static ({int width, int height})? _readJpegDimensions(Uint8List bytes) {
    if (bytes.length < 4) return null;
    var offset = 2;
    while (offset + 1 < bytes.length) {
      if (bytes[offset] != 0xff) {
        offset++;
        continue;
      }
      while (offset < bytes.length && bytes[offset] == 0xff) {
        offset++;
      }
      if (offset >= bytes.length) return null;
      final marker = bytes[offset++];
      if (marker == 0xd8 || marker == 0xd9) continue;
      if (marker == 0xda) return null;
      if ((marker >= 0xd0 && marker <= 0xd7) || marker == 0x01) continue;
      if (offset + 2 > bytes.length) return null;
      final length = _u16be(bytes, offset);
      if (length < 2 || offset + length > bytes.length) return null;
      if (_isJpegSof(marker) && length >= 7) {
        return (
          width: _u16be(bytes, offset + 5),
          height: _u16be(bytes, offset + 3),
        );
      }
      offset += length;
    }
    return null;
  }

  static ({int width, int height})? _readWebpDimensions(Uint8List bytes) {
    if (bytes.length < 20 ||
        !_matches(bytes, 12, const [0x56, 0x50, 0x38, 0x58]) &&
            !_matches(bytes, 12, const [0x56, 0x50, 0x38, 0x20]) &&
            !_matches(bytes, 12, const [0x56, 0x50, 0x38, 0x4c])) {
      return null;
    }
    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final data = offset + 8;
      final length = _u32le(bytes, offset + 4);
      final end = data + length;
      if (end > bytes.length) return null;
      if (_matches(bytes, offset, const [0x56, 0x50, 0x38, 0x58]) &&
          length >= 10 &&
          data + 10 <= bytes.length) {
        return (
          width: 1 + _u24le(bytes, data + 4),
          height: 1 + _u24le(bytes, data + 7),
        );
      }
      if (_matches(bytes, offset, const [0x56, 0x50, 0x38, 0x20]) &&
          length >= 10 &&
          data + 10 <= bytes.length &&
          _matches(bytes, data + 3, const [0x9d, 0x01, 0x2a])) {
        return (
          width: _u16le(bytes, data + 6),
          height: _u16le(bytes, data + 8),
        );
      }
      if (_matches(bytes, offset, const [0x56, 0x50, 0x38, 0x4c]) &&
          length >= 5 &&
          data + 5 <= bytes.length &&
          bytes[data] == 0x2f) {
        final second = bytes[data + 1];
        final third = bytes[data + 2];
        return (
          width: 1 + second + ((third & 0x3f) << 8),
          height:
              1 +
              ((third >> 6) |
                  (bytes[data + 3] << 2) |
                  ((bytes[data + 4] & 0x0f) << 10)),
        );
      }
      offset = data + length + (length.isOdd ? 1 : 0);
    }
    return null;
  }

  static bool _isJpegSof(int marker) => <int>{
    0xc0,
    0xc1,
    0xc2,
    0xc3,
    0xc5,
    0xc6,
    0xc7,
    0xc9,
    0xca,
    0xcb,
    0xcd,
    0xce,
    0xcf,
  }.contains(marker);

  static bool _matches(Uint8List bytes, int offset, List<int> expected) {
    if (offset < 0 || offset + expected.length > bytes.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (bytes[offset + index] != expected[index]) return false;
    }
    return true;
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
