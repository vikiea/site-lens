import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The sealing scheme the interface answers with.
///
/// ADR-0004 allows an adapter to do anything here as long as none of it leaks
/// outwards; this file is the only place that knows the interface seals `data`.
///
/// The published client derives the working key and IV at runtime from a
/// remote secret, and only falls back to the baked-in constants on first
/// launch. **Using the baked-in constants against live data fails the padding
/// check** — that is recorded in the reference report, so this opener takes the
/// remote secret when it has one and reports the failure as an ordinary
/// adapter failure when it does not. It never retries and never invents a key.
class HuangguoOpener {
  const HuangguoOpener({this.remoteSecret});

  /// The 80 raw bytes the interface's own client fetches from its fixed
  /// secret file, already fetched by the adapter's transport. Null when the
  /// fetch failed; the opener then answers [canOpen] `false` instead of
  /// pretending the constants are enough.
  final Uint8List? remoteSecret;

  /// Whether a sealed payload can be opened at all right now.
  bool get canOpen {
    final secret = remoteSecret;
    return secret != null && secret.length >= 64;
  }

  /// Opens [sealed] (Base64 of an AES-128-CBC/PKCS7 ciphertext) and returns the
  /// UTF-8 text inside. Throws [FormatException] when the payload cannot be
  /// opened, so the caller reports one ordinary failure.
  String open(String sealedBase64) {
    final secret = remoteSecret;
    if (secret == null || secret.length < 64) {
      throw const FormatException('响应是密文，但当前没有可用的密钥');
    }
    final List<int> cipher;
    try {
      cipher = base64Decode(
        sealedBase64.replaceAll('-', '+').replaceAll('_', '/'),
      );
    } on FormatException {
      throw const FormatException('响应密文不是合法 Base64');
    }
    if (cipher.isEmpty || cipher.length % 16 != 0) {
      throw const FormatException('响应密文长度不是 16 的倍数');
    }
    // 80 bytes split into two 32-byte halves; each half becomes a 64-digit hex
    // string, and the 3600-second hint is appended by the client before the
    // string is used as the key/IV material.
    final keyHex = _hex(secret.sublist(0, 32));
    final ivHex = _hex(secret.sublist(32, 64));
    final key = _first16(utf8.encode('$keyHex$_ttlSuffix'));
    final iv = _first16(utf8.encode('$ivHex$_ttlSuffix'));
    final plain = _cbcDecrypt(cipher, key, iv);
    return utf8.decode(plain, allowMalformed: true);
  }

  static const _ttlSuffix = '_3600';

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _first16(List<int> bytes) => bytes.sublist(0, 16);

  /// AES-128-CBC with PKCS7 removal. Kept here rather than in a new dependency
  /// because the project forbids adding packages for one adapter's scheme.
  static List<int> _cbcDecrypt(List<int> cipher, List<int> key, List<int> iv) {
    if (key.length != 16 || iv.length != 16) {
      throw const FormatException('密钥或初始向量长度不是 16 字节');
    }
    final out = Uint8List(cipher.length);
    var previous = Uint8List.fromList(iv);
    for (var offset = 0; offset < cipher.length; offset += 16) {
      final block = Uint8List.fromList(cipher.sublist(offset, offset + 16));
      final decrypted = _decryptBlock(block, key);
      for (var i = 0; i < 16; i++) {
        out[offset + i] = decrypted[i] ^ previous[i];
      }
      previous = block;
    }
    if (out.isEmpty) throw const FormatException('响应密文为空');
    final pad = out.last;
    if (pad < 1 || pad > 16 || pad > out.length) {
      throw const FormatException('响应解密失败（填充不合法）');
    }
    for (var i = out.length - pad; i < out.length; i++) {
      if (out[i] != pad) {
        throw const FormatException('响应解密失败（填充不合法）');
      }
    }
    return out.sublist(0, out.length - pad);
  }

  static Uint8List _decryptBlock(Uint8List block, List<int> key) {
    // AES-128 decryption: initial AddRoundKey with the last round key, then
    // nine inverse rounds and a final inverse round without MixColumns.
    final roundKeys = _expandKey(key);
    var state = Uint8List.fromList(block);
    _addRoundKey(state, roundKeys, 10);
    for (var round = 9; round >= 1; round--) {
      _invShiftRows(state);
      _invSubBytes(state);
      _addRoundKey(state, roundKeys, round);
      _invMixColumns(state);
    }
    _invShiftRows(state);
    _invSubBytes(state);
    _addRoundKey(state, roundKeys, 0);
    return state;
  }

  static void _addRoundKey(Uint8List state, List<int> roundKeys, int round) {
    for (var i = 0; i < 16; i++) {
      state[i] ^= roundKeys[round * 16 + i];
    }
  }
}

/// AES-128 round keys: the 16 key bytes plus 10 expanded round keys.
List<int> _expandKey(List<int> key) {
  final expanded = List<int>.filled(176, 0);
  expanded.setRange(0, 16, key);
  var bytesGenerated = 16;
  var rcon = 1;
  final temp = List<int>.filled(4, 0);
  while (bytesGenerated < 176) {
    temp.setRange(0, 4, expanded.sublist(bytesGenerated - 4, bytesGenerated));
    if (bytesGenerated % 16 == 0) {
      final first = temp.removeAt(0);
      temp.add(first);
      for (var i = 0; i < 4; i++) {
        temp[i] = _sbox[temp[i]];
      }
      temp[0] ^= rcon;
      rcon = _xtime(rcon);
    }
    for (var i = 0; i < 4; i++) {
      expanded[bytesGenerated] = expanded[bytesGenerated - 16] ^ temp[i];
      bytesGenerated++;
    }
  }
  return expanded;
}

void _invSubBytes(Uint8List state) {
  for (var i = 0; i < 16; i++) {
    state[i] = _invSbox[state[i]];
  }
}

void _invShiftRows(Uint8List state) {
  final copy = Uint8List.fromList(state);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 4; col++) {
      state[row + 4 * ((col + row) % 4)] = copy[row + 4 * col];
    }
  }
}

void _invMixColumns(Uint8List state) {
  for (var col = 0; col < 4; col++) {
    final a0 = state[4 * col];
    final a1 = state[4 * col + 1];
    final a2 = state[4 * col + 2];
    final a3 = state[4 * col + 3];
    state[4 * col] =
        _gmul(a0, 14) ^ _gmul(a1, 11) ^ _gmul(a2, 13) ^ _gmul(a3, 9);
    state[4 * col + 1] =
        _gmul(a0, 9) ^ _gmul(a1, 14) ^ _gmul(a2, 11) ^ _gmul(a3, 13);
    state[4 * col + 2] =
        _gmul(a0, 13) ^ _gmul(a1, 9) ^ _gmul(a2, 14) ^ _gmul(a3, 11);
    state[4 * col + 3] =
        _gmul(a0, 11) ^ _gmul(a1, 13) ^ _gmul(a2, 9) ^ _gmul(a3, 14);
  }
}

int _xtime(int value) =>
    ((value << 1) ^ ((value & 0x80) != 0 ? 0x1b : 0)) & 0xff;

int _gmul(int a, int b) {
  var result = 0;
  var x = a;
  var y = b;
  while (y > 0) {
    if (y & 1 != 0) result ^= x;
    x = _xtime(x);
    y >>= 1;
  }
  return result & 0xff;
}

/// MD5-shaped short digest, used only for cache keys inside this adapter.
String huangguoDigest(String text) => md5.convert(utf8.encode(text)).toString();

const _sbox = <int>[
  0x63,
  0x7c,
  0x77,
  0x7b,
  0xf2,
  0x6b,
  0x6f,
  0xc5,
  0x30,
  0x01,
  0x67,
  0x2b,
  0xfe,
  0xd7,
  0xab,
  0x76,
  0xca,
  0x82,
  0xc9,
  0x7d,
  0xfa,
  0x59,
  0x47,
  0xf0,
  0xad,
  0xd4,
  0xa2,
  0xaf,
  0x9c,
  0xa4,
  0x72,
  0xc0,
  0xb7,
  0xfd,
  0x93,
  0x26,
  0x36,
  0x3f,
  0xf7,
  0xcc,
  0x34,
  0xa5,
  0xe5,
  0xf1,
  0x71,
  0xd8,
  0x31,
  0x15,
  0x04,
  0xc7,
  0x23,
  0xc3,
  0x18,
  0x96,
  0x05,
  0x9a,
  0x07,
  0x12,
  0x80,
  0xe2,
  0xeb,
  0x27,
  0xb2,
  0x75,
  0x09,
  0x83,
  0x2c,
  0x1a,
  0x1b,
  0x6e,
  0x5a,
  0xa0,
  0x52,
  0x3b,
  0xd6,
  0xb3,
  0x29,
  0xe3,
  0x2f,
  0x84,
  0x53,
  0xd1,
  0x00,
  0xed,
  0x20,
  0xfc,
  0xb1,
  0x5b,
  0x6a,
  0xcb,
  0xbe,
  0x39,
  0x4a,
  0x4c,
  0x58,
  0xcf,
  0xd0,
  0xef,
  0xaa,
  0xfb,
  0x43,
  0x4d,
  0x33,
  0x85,
  0x45,
  0xf9,
  0x02,
  0x7f,
  0x50,
  0x3c,
  0x9f,
  0xa8,
  0x51,
  0xa3,
  0x40,
  0x8f,
  0x92,
  0x9d,
  0x38,
  0xf5,
  0xbc,
  0xb6,
  0xda,
  0x21,
  0x10,
  0xff,
  0xf3,
  0xd2,
  0xcd,
  0x0c,
  0x13,
  0xec,
  0x5f,
  0x97,
  0x44,
  0x17,
  0xc4,
  0xa7,
  0x7e,
  0x3d,
  0x64,
  0x5d,
  0x19,
  0x73,
  0x60,
  0x81,
  0x4f,
  0xdc,
  0x22,
  0x2a,
  0x90,
  0x88,
  0x46,
  0xee,
  0xb8,
  0x14,
  0xde,
  0x5e,
  0x0b,
  0xdb,
  0xe0,
  0x32,
  0x3a,
  0x0a,
  0x49,
  0x06,
  0x24,
  0x5c,
  0xc2,
  0xd3,
  0xac,
  0x62,
  0x91,
  0x95,
  0xe4,
  0x79,
  0xe7,
  0xc8,
  0x37,
  0x6d,
  0x8d,
  0xd5,
  0x4e,
  0xa9,
  0x6c,
  0x56,
  0xf4,
  0xea,
  0x65,
  0x7a,
  0xae,
  0x08,
  0xba,
  0x78,
  0x25,
  0x2e,
  0x1c,
  0xa6,
  0xb4,
  0xc6,
  0xe8,
  0xdd,
  0x74,
  0x1f,
  0x4b,
  0xbd,
  0x8b,
  0x8a,
  0x70,
  0x3e,
  0xb5,
  0x66,
  0x48,
  0x03,
  0xf6,
  0x0e,
  0x61,
  0x35,
  0x57,
  0xb9,
  0x86,
  0xc1,
  0x1d,
  0x9e,
  0xe1,
  0xf8,
  0x98,
  0x11,
  0x69,
  0xd9,
  0x8e,
  0x94,
  0x9b,
  0x1e,
  0x87,
  0xe9,
  0xce,
  0x55,
  0x28,
  0xdf,
  0x8c,
  0xa1,
  0x89,
  0x0d,
  0xbf,
  0xe6,
  0x42,
  0x68,
  0x41,
  0x99,
  0x2d,
  0x0f,
  0xb0,
  0x54,
  0xbb,
  0x16,
];

const _invSbox = <int>[
  0x52,
  0x09,
  0x6a,
  0xd5,
  0x30,
  0x36,
  0xa5,
  0x38,
  0xbf,
  0x40,
  0xa3,
  0x9e,
  0x81,
  0xf3,
  0xd7,
  0xfb,
  0x7c,
  0xe3,
  0x39,
  0x82,
  0x9b,
  0x2f,
  0xff,
  0x87,
  0x34,
  0x8e,
  0x43,
  0x44,
  0xc4,
  0xde,
  0xe9,
  0xcb,
  0x54,
  0x7b,
  0x94,
  0x32,
  0xa6,
  0xc2,
  0x23,
  0x3d,
  0xee,
  0x4c,
  0x95,
  0x0b,
  0x42,
  0xfa,
  0xc3,
  0x4e,
  0x08,
  0x2e,
  0xa1,
  0x66,
  0x28,
  0xd9,
  0x24,
  0xb2,
  0x76,
  0x5b,
  0xa2,
  0x49,
  0x6d,
  0x8b,
  0xd1,
  0x25,
  0x72,
  0xf8,
  0xf6,
  0x64,
  0x86,
  0x68,
  0x98,
  0x16,
  0xd4,
  0xa4,
  0x5c,
  0xcc,
  0x5d,
  0x65,
  0xb6,
  0x92,
  0x6c,
  0x70,
  0x48,
  0x50,
  0xfd,
  0xed,
  0xb9,
  0xda,
  0x5e,
  0x15,
  0x46,
  0x57,
  0xa7,
  0x8d,
  0x9d,
  0x84,
  0x90,
  0xd8,
  0xab,
  0x00,
  0x8c,
  0xbc,
  0xd3,
  0x0a,
  0xf7,
  0xe4,
  0x58,
  0x05,
  0xb8,
  0xb3,
  0x45,
  0x06,
  0xd0,
  0x2c,
  0x1e,
  0x8f,
  0xca,
  0x3f,
  0x0f,
  0x02,
  0xc1,
  0xaf,
  0xbd,
  0x03,
  0x01,
  0x13,
  0x8a,
  0x6b,
  0x3a,
  0x91,
  0x11,
  0x41,
  0x4f,
  0x67,
  0xdc,
  0xea,
  0x97,
  0xf2,
  0xcf,
  0xce,
  0xf0,
  0xb4,
  0xe6,
  0x73,
  0x96,
  0xac,
  0x74,
  0x22,
  0xe7,
  0xad,
  0x35,
  0x85,
  0xe2,
  0xf9,
  0x37,
  0xe8,
  0x1c,
  0x75,
  0xdf,
  0x6e,
  0x47,
  0xf1,
  0x1a,
  0x71,
  0x1d,
  0x29,
  0xc5,
  0x89,
  0x6f,
  0xb7,
  0x62,
  0x0e,
  0xaa,
  0x18,
  0xbe,
  0x1b,
  0xfc,
  0x56,
  0x3e,
  0x4b,
  0xc6,
  0xd2,
  0x79,
  0x20,
  0x9a,
  0xdb,
  0xc0,
  0xfe,
  0x78,
  0xcd,
  0x5a,
  0xf4,
  0x1f,
  0xdd,
  0xa8,
  0x33,
  0x88,
  0x07,
  0xc7,
  0x31,
  0xb1,
  0x12,
  0x10,
  0x59,
  0x27,
  0x80,
  0xec,
  0x5f,
  0x60,
  0x51,
  0x7f,
  0xa9,
  0x19,
  0xb5,
  0x4a,
  0x0d,
  0x2d,
  0xe5,
  0x7a,
  0x9f,
  0x93,
  0xc9,
  0x9c,
  0xef,
  0xa0,
  0xe0,
  0x3b,
  0x4d,
  0xae,
  0x2a,
  0xf5,
  0xb0,
  0xc8,
  0xeb,
  0xbb,
  0x3c,
  0x83,
  0x53,
  0x99,
  0x61,
  0x17,
  0x2b,
  0x04,
  0x7e,
  0xba,
  0x77,
  0xd6,
  0x26,
  0xe1,
  0x69,
  0x14,
  0x63,
  0x55,
  0x21,
  0x0c,
  0x7d,
];
