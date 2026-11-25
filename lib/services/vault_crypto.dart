import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class ChaCha20 {
  ChaCha20._();

  static const int _mask = 0xFFFFFFFF;

  static Uint8List xor(Uint8List key, Uint8List nonce, int counter, Uint8List data) {
    if (key.length != 32 || nonce.length != 12) {
      throw ArgumentError('ChaCha20 needs a 32 byte key and a 12 byte nonce');
    }
    final out = Uint8List(data.length);
    if (data.isEmpty) return out;
    final input = Uint32List(16);
    final work = Uint32List(16);
    final keyView = ByteData.sublistView(key);
    final nonceView = ByteData.sublistView(nonce);
    input[0] = 0x61707865;
    input[1] = 0x3320646e;
    input[2] = 0x79622d32;
    input[3] = 0x6b206574;
    for (var i = 0; i < 8; i++) {
      input[4 + i] = keyView.getUint32(i * 4, Endian.little);
    }
    input[12] = counter & _mask;
    for (var i = 0; i < 3; i++) {
      input[13 + i] = nonceView.getUint32(i * 4, Endian.little);
    }
    var offset = 0;
    while (offset < data.length) {
      work.setAll(0, input);
      for (var round = 0; round < 10; round++) {
        _quarter(work, 0, 4, 8, 12);
        _quarter(work, 1, 5, 9, 13);
        _quarter(work, 2, 6, 10, 14);
        _quarter(work, 3, 7, 11, 15);
        _quarter(work, 0, 5, 10, 15);
        _quarter(work, 1, 6, 11, 12);
        _quarter(work, 2, 7, 8, 13);
        _quarter(work, 3, 4, 9, 14);
      }
      for (var i = 0; i < 16; i++) {
        work[i] = (work[i] + input[i]) & _mask;
      }
      final left = data.length - offset;
      final take = left < 64 ? left : 64;
      for (var i = 0; i < take; i++) {
        out[offset + i] = data[offset + i] ^ ((work[i >> 2] >> ((i & 3) * 8)) & 0xFF);
      }
      offset += take;
      input[12] = (input[12] + 1) & _mask;
    }
    return out;
  }

  static void _quarter(Uint32List x, int a, int b, int c, int d) {
    x[a] = (x[a] + x[b]) & _mask;
    x[d] = _rotl(x[d] ^ x[a], 16);
    x[c] = (x[c] + x[d]) & _mask;
    x[b] = _rotl(x[b] ^ x[c], 12);
    x[a] = (x[a] + x[b]) & _mask;
    x[d] = _rotl(x[d] ^ x[a], 8);
    x[c] = (x[c] + x[d]) & _mask;
    x[b] = _rotl(x[b] ^ x[c], 7);
  }

  static int _rotl(int value, int bits) =>
      ((value << bits) | (value >> (32 - bits))) & _mask;
}

class VaultCrypto {
  VaultCrypto(Uint8List masterKey)
      : _encKey = _derive(masterKey, 'xtify-vault/enc/v1'),
        _macKey = _derive(masterKey, 'xtify-vault/mac/v1');

  static const int keyLength = 32;
  static const int _nonceLength = 16;
  static const int _tagLength = 32;
  static const int _headLength = 4;
  static const List<int> _magic = [0x58, 0x56, 0x31, 0x00];
  static const int overhead = _headLength + _nonceLength + _tagLength;
  static const int maxLength = 64 * 1024 * 1024;

  static final Random _random = Random.secure();
  static final Uint8List _zeroNonce = Uint8List(12);

  final Uint8List _encKey;
  final Uint8List _macKey;

  static Uint8List _derive(Uint8List key, String label) =>
      Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode(label)).bytes);

  static Uint8List randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }

  Uint8List seal(Uint8List plain, String label) {
    if (plain.length > maxLength) throw ArgumentError('value is too large');
    return _sealWith(randomBytes(_nonceLength), plain, label);
  }

  // A blob that starts with "XV" but is not version 1 was written by another
  // version of Xtify. It is not damaged, so it must never be renamed, replaced
  // or deleted, only left alone until a version that knows the format runs.
  static bool isOtherVersion(Uint8List blob) {
    if (blob.length < _headLength) return false;
    if (blob[0] != _magic[0] || blob[1] != _magic[1]) return false;
    for (var i = 2; i < _headLength; i++) {
      if (blob[i] != _magic[i]) return true;
    }
    return false;
  }

  Uint8List? open(Uint8List blob, String label) {
    if (blob.length < overhead) return null;
    for (var i = 0; i < _headLength; i++) {
      if (blob[i] != _magic[i]) return null;
    }
    final bodyEnd = blob.length - _tagLength;
    final expected = _tag(blob, bodyEnd, label);
    var diff = 0;
    for (var i = 0; i < _tagLength; i++) {
      diff |= expected[i] ^ blob[bodyEnd + i];
    }
    if (diff != 0) return null;
    return _stream(
      Uint8List.sublistView(blob, _headLength, _headLength + _nonceLength),
      Uint8List.sublistView(blob, _headLength + _nonceLength, bodyEnd),
    );
  }

  Uint8List _sealWith(Uint8List nonce, Uint8List plain, String label) {
    final body = _stream(nonce, plain);
    final bodyEnd = _headLength + _nonceLength + body.length;
    final out = Uint8List(bodyEnd + _tagLength);
    out.setRange(0, _headLength, _magic);
    out.setRange(_headLength, _headLength + _nonceLength, nonce);
    out.setRange(_headLength + _nonceLength, bodyEnd, body);
    out.setRange(bodyEnd, out.length, _tag(out, bodyEnd, label));
    return out;
  }

  Uint8List _stream(Uint8List nonce, Uint8List data) {
    final key = Uint8List.fromList(Hmac(sha256, _encKey).convert(nonce).bytes);
    return ChaCha20.xor(key, _zeroNonce, 1, data);
  }

  Uint8List _tag(Uint8List data, int end, String label) {
    final name = utf8.encode(label);
    final input = Uint8List(end + name.length + 4);
    input.setRange(0, end, data);
    input.setRange(end, end + name.length, name);
    ByteData.sublistView(input).setUint32(end + name.length, name.length, Endian.big);
    return Uint8List.fromList(Hmac(sha256, _macKey).convert(input).bytes);
  }

  static const String _sampleText =
      "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";

  static const String _cipherExpected =
      '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b'
      'f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8'
      '07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736'
      '5af90bbf74a35be6b40b8eedf2785e42874d';

  static const String _macExpected =
      '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843';

  static const String _sealExpected =
      '58563100a0a1a2a3a4a5a6a7a8a9aaabacadaeaf9b2638e9967eae7769227bb4'
      'f28aaa1c1105a3421fbe37d4244d6e85ef70bcfe668544486cf80db4434e0f16'
      'e6f4f2d64575d3a74c9a98ca4d27a4dcdb7e20c980e9707828c6070c007fb742'
      '71061df8c03f3e04e0f2a4c2df84c050635098722afa3f25c34a82d03a6126ab'
      '0097a165e443590c55822df8c72ad48dfb5f885072c2765670b4f28539f4d32e'
      '3fdf3635777f';

  static String? selfTest() {
    try {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final text = Uint8List.fromList(utf8.encode(_sampleText));
      final cipher = ChaCha20.xor(key, _fromHex('000000000000004a00000000'), 1, text);
      if (_toHex(cipher) != _cipherExpected) return 'cipher check failed';
      final mac = Hmac(sha256, utf8.encode('Jefe'))
          .convert(utf8.encode('what do ya want for nothing?'));
      if (mac.toString() != _macExpected) return 'mac check failed';
      final box = VaultCrypto(key);
      final nonce = Uint8List.fromList(List<int>.generate(16, (i) => 0xA0 + i));
      final blob = box._sealWith(nonce, text, 'selftest');
      if (_toHex(blob) != _sealExpected) return 'seal check failed';
      final back = box.open(blob, 'selftest');
      if (back == null || _toHex(back) != _toHex(text)) return 'open check failed';
      if (box.open(blob, 'other') != null) return 'label check failed';
      final damaged = Uint8List.fromList(blob);
      damaged[30] ^= 1;
      if (box.open(damaged, 'selftest') != null) return 'tamper check failed';
      final fresh = box.open(box.seal(text, 'selftest'), 'selftest');
      if (fresh == null || _toHex(fresh) != _toHex(text)) return 'round trip failed';
      return null;
    } catch (e) {
      return 'self test error: $e';
    }
  }

  static Uint8List _fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String _toHex(List<int> bytes) {
    final out = StringBuffer();
    for (final b in bytes) {
      out.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}
