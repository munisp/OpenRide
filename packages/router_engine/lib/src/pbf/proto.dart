/// Hand-rolled protobuf wire-format reader (SPEC §3.1).
///
/// Supports varint, fixed32, fixed64 and length-delimited fields with a
/// small typed accessor layer. No code generation, no dependencies.
library proto;

import 'dart:convert';
import 'dart:typed_data';

/// Wire types from the protobuf spec.
class WireType {
  static const int varint = 0;
  static const int fixed64 = 1;
  static const int lengthDelimited = 2;
  static const int fixed32 = 5;
}

/// A cursor over a length-delimited protobuf message.
class ProtoReader {
  final Uint8List _buf;
  int _pos = 0;
  final int _end;

  ProtoReader(Uint8List data, [int start = 0, int? end])
      : _buf = data,
        _pos = start,
        _end = end ?? data.length;

  bool get hasMore => _pos < _end;

  /// Reads the next field key; returns (fieldNumber, wireType).
  /// Caller must have checked [hasMore].
  (int, int) readKey() {
    final key = readVarint();
    return (key >> 3, key & 7);
  }

  /// Reads a varint. Dart ints are 64-bit two's complement, so a varint
  /// encoding a negative int64 (10 bytes) naturally wraps to its signed
  /// value; unsigned values in OSM PBF never exceed 2^63-1.
  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (_pos >= _end) {
        throw const FormatException('truncated varint');
      }
      final b = _buf[_pos++];
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 63) {
        // Consume remaining bytes of an over-long varint defensively.
        while (_pos < _end && (_buf[_pos++] & 0x80) != 0) {}
        break;
      }
    }
    return result;
  }

  int readUvarint() => readVarint();

  int readSint64() {
    final v = readUvarint();
    // zigzag decode: (v >> 1) ^ -(v & 1), wrapping 64-bit arithmetic.
    return (v >> 1) ^ -(v & 1);
  }

  int readFixed32() {
    if (_pos + 4 > _end) throw const FormatException('truncated fixed32');
    final v = ByteData.sublistView(_buf, _pos, _pos + 4).getUint32(0, Endian.little);
    _pos += 4;
    return v;
  }

  int readFixed64() {
    if (_pos + 8 > _end) throw const FormatException('truncated fixed64');
    final v = ByteData.sublistView(_buf, _pos, _pos + 8).getUint64(0, Endian.little);
    _pos += 8;
    return v;
  }

  /// Reads a length-delimited field, returning a sub-view of the buffer.
  Uint8List readBytes() {
    final len = readUvarint();
    if (len < 0 || _pos + len > _end) {
      throw const FormatException('truncated length-delimited field');
    }
    final out = Uint8List.sublistView(_buf, _pos, _pos + len);
    _pos += len;
    return out;
  }

  String readString() => utf8.decode(readBytes());

  /// Skips a field of the given wire type.
  void skip(int wireType) {
    switch (wireType) {
      case WireType.varint:
        readUvarint();
        break;
      case WireType.fixed64:
        _pos += 8;
        break;
      case WireType.lengthDelimited:
        final len = readUvarint();
        _pos += len;
        break;
      case WireType.fixed32:
        _pos += 4;
        break;
      default:
        throw FormatException('unknown wire type $wireType');
    }
    if (_pos > _end) throw const FormatException('skip past end');
  }

  /// Reads a packed repeated varint field.
  List<int> readPackedVarint() {
    final bytes = readBytes();
    final r = ProtoReader(bytes);
    final out = <int>[];
    while (r.hasMore) {
      out.add(r.readVarint());
    }
    return out;
  }

  /// Reads a packed repeated sint (zigzag) field.
  List<int> readPackedSint64() {
    final bytes = readBytes();
    final r = ProtoReader(bytes);
    final out = <int>[];
    while (r.hasMore) {
      out.add(r.readSint64());
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Minimal writer, used by the .osm.pbf fixture writer in test/ and by the
// graph serializer is separate; this writer is generic protobuf.
// ---------------------------------------------------------------------------

class ProtoWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  static Uint8List varintBytes(int v) {
    final w = ProtoWriter();
    w.writeVarintRaw(v);
    return w.takeBytes();
  }

  void writeVarintRaw(int v) {
    if (v >= 0) {
      var value = v;
      while (value >= 0x80) {
        _b.addByte((value & 0x7f) | 0x80);
        value >>= 7;
      }
      _b.addByte(value);
    } else {
      // Negative int64: canonical 10-byte two's complement encoding.
      var value = v;
      for (var i = 0; i < 9; i++) {
        _b.addByte((value & 0x7f) | 0x80);
        value >>= 7; // arithmetic shift keeps sign
      }
      _b.addByte(1);
    }
  }

  void writeKey(int field, int wireType) => writeVarintRaw((field << 3) | wireType);

  void writeVarint(int field, int v) {
    writeKey(field, WireType.varint);
    writeVarintRaw(v);
  }

  void writeSint64(int field, int v) {
    writeKey(field, WireType.varint);
    final zz = v >= 0 ? v << 1 : ((-v - 1) << 1) | 1;
    writeVarintRaw(zz);
  }

  void writeFixed32(int field, int v) {
    writeKey(field, WireType.fixed32);
    final bd = ByteData(4)..setUint32(0, v, Endian.little);
    _b.add(bd.buffer.asUint8List());
  }

  void writeFixed64(int field, int v) {
    writeKey(field, WireType.fixed64);
    final bd = ByteData(8)..setUint64(0, v, Endian.little);
    _b.add(bd.buffer.asUint8List());
  }

  void writeBytes(int field, Uint8List bytes) {
    writeKey(field, WireType.lengthDelimited);
    writeVarintRaw(bytes.length);
    _b.add(bytes);
  }

  void writeString(int field, String s) =>
      writeBytes(field, Uint8List.fromList(utf8.encode(s)));

  /// Writes a packed varint field.
  void writePackedVarint(int field, List<int> values) {
    final w = ProtoWriter();
    for (final v in values) {
      w.writeVarintRaw(v);
    }
    writeBytes(field, w.takeBytes());
  }

  /// Writes a packed sint64 (zigzag) field.
  void writePackedSint64(int field, List<int> values) {
    final w = ProtoWriter();
    for (final v in values) {
      final zz = v >= 0 ? v << 1 : ((-v - 1) << 1) | 1;
      w.writeVarintRaw(zz);
    }
    writeBytes(field, w.takeBytes());
  }

  Uint8List takeBytes() => _b.takeBytes();
}
