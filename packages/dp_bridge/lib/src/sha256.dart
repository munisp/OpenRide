/// Minimal pure-Dart SHA-256 (FIPS 180-4) used for bundle integrity checks.
///
/// Zero-dependency incremental hasher: feed arbitrary chunks via [Sha256.add]
/// and finalize with [Sha256.close]. Convenience helpers [sha256Hex] and
/// [sha256FileHex] cover the common one-shot cases.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const List<int> _h0 = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// Incremental SHA-256 hasher.
class Sha256 {
  final Uint32List _state = Uint32List.fromList(_h0);
  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _pendingLen = 0;
  int _totalBytes = 0;
  bool _closed = false;

  void add(List<int> data) {
    if (_closed) throw StateError('Sha256 already closed');
    if (data.isEmpty) return;
    _totalBytes += data.length;
    _pending.add(data);
    _pendingLen += data.length;
    if (_pendingLen >= 64) {
      final buf = _pending.takeBytes();
      var offset = 0;
      while (buf.length - offset >= 64) {
        _compress(buf, offset);
        offset += 64;
      }
      final rest = buf.length - offset;
      if (rest > 0) {
        _pending.add(Uint8List.fromList(buf.sublist(offset)));
      }
      _pendingLen = rest;
    }
  }

  /// Finalizes and returns the 32-byte digest.
  Uint8List close() {
    if (_closed) throw StateError('Sha256 already closed');
    _closed = true;
    final bitLen = _totalBytes * 8;
    final tail = _pending.takeBytes();
    final pad = BytesBuilder(copy: false);
    pad.add(tail);
    pad.addByte(0x80);
    // Pad with zeros until length ≡ 56 (mod 64), then 8-byte big-endian length.
    final rem = (tail.length + 1) % 64;
    pad.add(Uint8List(rem <= 56 ? 56 - rem : 120 - rem));
    final lenBytes = ByteData(8);
    lenBytes.setUint32(0, (bitLen >> 32) & 0xFFFFFFFF);
    lenBytes.setUint32(4, bitLen & 0xFFFFFFFF);
    pad.add(lenBytes.buffer.asUint8List());
    final block = pad.takeBytes();
    for (var offset = 0; offset < block.length; offset += 64) {
      _compress(block, offset);
    }
    final digest = ByteData(32);
    for (var i = 0; i < 8; i++) {
      digest.setUint32(i * 4, _state[i]);
    }
    return digest.buffer.asUint8List();
  }

  void _compress(List<int> chunk, int offset) {
    final w = Uint32List(64);
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] = (chunk[j] << 24) | (chunk[j + 1] << 16) | (chunk[j + 2] << 8) | chunk[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = _state[0], b = _state[1], c = _state[2], d = _state[3];
    var e = _state[4], f = _state[5], g = _state[6], h = _state[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    _state[0] = (_state[0] + a) & 0xFFFFFFFF;
    _state[1] = (_state[1] + b) & 0xFFFFFFFF;
    _state[2] = (_state[2] + c) & 0xFFFFFFFF;
    _state[3] = (_state[3] + d) & 0xFFFFFFFF;
    _state[4] = (_state[4] + e) & 0xFFFFFFFF;
    _state[5] = (_state[5] + f) & 0xFFFFFFFF;
    _state[6] = (_state[6] + g) & 0xFFFFFFFF;
    _state[7] = (_state[7] + h) & 0xFFFFFFFF;
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// One-shot SHA-256 hex digest of [data].
String sha256Hex(List<int> data) {
  final h = Sha256()..add(data);
  return _hex(h.close());
}

/// Streaming SHA-256 hex digest of a file (chunked reads, low memory).
Future<String> sha256FileHex(String path) async {
  final h = Sha256();
  await for (final chunk in File(path).openRead()) {
    h.add(chunk);
  }
  return _hex(h.close());
}

/// UTF-8 convenience wrapper around [sha256Hex].
String sha256String(String s) => sha256Hex(utf8.encode(s));
