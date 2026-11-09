/// Minimal real Mapbox Vector Tile (MVT v2) encoder + decoder.
/// Hand-rolled protobuf wire format: varints, fixed32/64, length-delimited.
/// Geometry: zigzag delta encoding, MoveTo(1)/LineTo(2)/ClosePath(7) commands,
/// default extent 4096.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Geometry type codes per MVT spec.
enum MvtGeomType {
  unknown(0),
  point(1),
  linestring(2),
  polygon(3);

  final int code;
  const MvtGeomType(this.code);

  static MvtGeomType fromCode(int c) =>
      MvtGeomType.values.firstWhere((t) => t.code == c, orElse: () => MvtGeomType.unknown);
}

/// A point in tile-local integer coordinates (0..extent, may exceed with buffer).
class MvtPoint {
  final int x, y;
  const MvtPoint(this.x, this.y);

  @override
  bool operator ==(Object o) => o is MvtPoint && o.x == x && o.y == y;
  @override
  int get hashCode => Object.hash(x, y);
  @override
  String toString() => '($x,$y)';
}

/// One MVT feature.
///
/// [parts] interpretation by [type]:
/// - point: a single part holding all (multi)points
/// - linestring: one part per linestring
/// - polygon: one part per ring, exterior ring first
class MvtFeature {
  int id;
  MvtGeomType type;
  List<List<MvtPoint>> parts;
  Map<String, Object?> properties;

  MvtFeature({
    this.id = 0,
    required this.type,
    List<List<MvtPoint>>? parts,
    Map<String, Object?>? properties,
  })  : parts = parts ?? <List<MvtPoint>>[],
        properties = properties ?? <String, Object?>{};
}

class MvtLayer {
  String name;
  int extent;
  List<MvtFeature> features;

  MvtLayer(this.name, {this.extent = mvtDefaultExtent, List<MvtFeature>? features})
      : features = features ?? <MvtFeature>[];
}

const int mvtDefaultExtent = 4096;

// ---------------------------------------------------------------------------
// Protobuf wire writer
// ---------------------------------------------------------------------------

class _PbWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void writeRawVarint(int v) {
    var value = v & 0xFFFFFFFFFFFFFFFF;
    // Dart ints are 64-bit; encode unsigned LEB128.
    while (value > 0x7F) {
      _b.addByte((value & 0x7F) | 0x80);
      value >>= 7;
    }
    _b.addByte(value & 0x7F);
  }

  void writeTag(int field, int wireType) => writeRawVarint((field << 3) | wireType);

  void writeVarintField(int field, int v) {
    writeTag(field, 0);
    writeRawVarint(v);
  }

  void writeFixed64Field(int field, double d) {
    writeTag(field, 1);
    final bd = ByteData(8)..setFloat64(0, d, Endian.little);
    _b.add(bd.buffer.asUint8List());
  }

  void writeFixed32Field(int field, double f) {
    writeTag(field, 5);
    final bd = ByteData(4)..setFloat32(0, f, Endian.little);
    _b.add(bd.buffer.asUint8List());
  }

  void writeBytesField(int field, Uint8List bytes) {
    writeTag(field, 2);
    writeRawVarint(bytes.length);
    _b.add(bytes);
  }

  void writeStringField(int field, String s) =>
      writeBytesField(field, Uint8List.fromList(utf8.encode(s)));

  /// Packed repeated varint field.
  void writePackedVarints(int field, List<int> values) {
    final inner = _PbWriter();
    for (final v in values) {
      inner.writeRawVarint(v);
    }
    writeBytesField(field, inner.takeBytes());
  }

  Uint8List takeBytes() => Uint8List.fromList(_b.takeBytes());
}

// ---------------------------------------------------------------------------
// Protobuf wire reader
// ---------------------------------------------------------------------------

class _PbReader {
  final Uint8List data;
  int pos = 0;
  _PbReader(this.data);

  bool get eof => pos >= data.length;

  int readRawVarint() {
    int result = 0;
    int shift = 0;
    while (true) {
      if (pos >= data.length) {
        throw FormatException('truncated varint in protobuf stream');
      }
      final b = data[pos++];
      result |= (b & 0x7F) << shift;
      if (b < 0x80) break;
      shift += 7;
      if (shift > 63) throw const FormatException('varint too long');
    }
    return result;
  }

  /// Returns (fieldNumber, wireType).
  (int, int) readTag() {
    final v = readRawVarint();
    return (v >> 3, v & 0x7);
  }

  Uint8List readBytes() {
    final len = readRawVarint();
    if (pos + len > data.length) {
      throw const FormatException('truncated length-delimited field');
    }
    final out = Uint8List.sublistView(data, pos, pos + len);
    pos += len;
    return out;
  }

  String readString() => utf8.decode(readBytes());

  double readFixed64() {
    if (pos + 8 > data.length) throw const FormatException('truncated fixed64');
    final bd = ByteData.sublistView(data, pos, pos + 8);
    pos += 8;
    return bd.getFloat64(0, Endian.little);
  }

  double readFixed32() {
    if (pos + 4 > data.length) throw const FormatException('truncated fixed32');
    final bd = ByteData.sublistView(data, pos, pos + 4);
    pos += 4;
    return bd.getFloat32(0, Endian.little);
  }

  void skip(int wireType) {
    switch (wireType) {
      case 0:
        readRawVarint();
      case 1:
        pos += 8;
      case 2:
        pos += readRawVarint();
      case 5:
        pos += 4;
      default:
        throw FormatException('unsupported wire type $wireType');
    }
    if (pos > data.length) throw const FormatException('truncated protobuf field');
  }
}

int _zigzagEncode(int v) => (v << 1) ^ (v >> 63);
int _zigzagDecode(int v) => (v >> 1) ^ -(v & 1);

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

Uint8List _encodeValue(Object? v) {
  final w = _PbWriter();
  if (v is String) {
    w.writeStringField(1, v);
  } else if (v is bool) {
    w.writeVarintField(7, v ? 1 : 0);
  } else if (v is int) {
    if (v >= 0) {
      w.writeVarintField(4, v); // int64_value
    } else {
      w.writeVarintField(6, _zigzagEncode(v)); // sint64_value
    }
  } else if (v is double) {
    w.writeFixed64Field(3, v); // double_value
  } else if (v == null) {
    // encode as empty Value message (decodes back to null)
  } else {
    w.writeStringField(1, v.toString());
  }
  return w.takeBytes();
}

Object? _decodeValue(Uint8List bytes) {
  final r = _PbReader(bytes);
  Object? value;
  while (!r.eof) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        value = r.readString();
      case 2:
        value = r.readFixed32();
      case 3:
        value = r.readFixed64();
      case 4:
        value = r.readRawVarint();
      case 5:
        value = r.readRawVarint();
      case 6:
        value = _zigzagDecode(r.readRawVarint());
      case 7:
        value = r.readRawVarint() != 0;
      default:
        r.skip(wire);
    }
  }
  return value;
}

// ---------------------------------------------------------------------------
// Geometry encoding / decoding
// ---------------------------------------------------------------------------

const int _cmdMoveTo = 1;
const int _cmdLineTo = 2;
const int _cmdClosePath = 7;

List<int> _encodeGeometry(MvtFeature f) {
  final g = <int>[];
  int cx = 0, cy = 0;

  void moveTo(MvtPoint p) {
    g.add((_cmdMoveTo & 0x7) | (1 << 3));
    g.add(_zigzagEncode(p.x - cx));
    g.add(_zigzagEncode(p.y - cy));
    cx = p.x;
    cy = p.y;
  }

  void lineTo(List<MvtPoint> pts, int from) {
    final count = pts.length - from;
    if (count <= 0) return;
    g.add((_cmdLineTo & 0x7) | (count << 3));
    for (int i = from; i < pts.length; i++) {
      g.add(_zigzagEncode(pts[i].x - cx));
      g.add(_zigzagEncode(pts[i].y - cy));
      cx = pts[i].x;
      cy = pts[i].y;
    }
  }

  switch (f.type) {
    case MvtGeomType.point:
      final pts = f.parts.expand((p) => p).toList();
      if (pts.isEmpty) break;
      g.add((_cmdMoveTo & 0x7) | (pts.length << 3));
      for (final p in pts) {
        g.add(_zigzagEncode(p.x - cx));
        g.add(_zigzagEncode(p.y - cy));
        cx = p.x;
        cy = p.y;
      }
    case MvtGeomType.linestring:
      for (final line in f.parts) {
        if (line.isEmpty) continue;
        moveTo(line.first);
        lineTo(line, 1);
      }
    case MvtGeomType.polygon:
      for (final ring in f.parts) {
        var pts = ring;
        // Drop duplicated closing point; ClosePath implies closure.
        if (pts.length > 1 && pts.first == pts.last) {
          pts = pts.sublist(0, pts.length - 1);
        }
        if (pts.length < 3) continue;
        moveTo(pts.first);
        lineTo(pts, 1);
        g.add((_cmdClosePath & 0x7) | (1 << 3));
      }
    case MvtGeomType.unknown:
      break;
  }
  return g;
}

List<List<MvtPoint>> _decodeGeometry(MvtGeomType type, List<int> geom) {
  final parts = <List<MvtPoint>>[];
  int i = 0;
  int cx = 0, cy = 0;
  while (i < geom.length) {
    final cmdInt = geom[i++];
    final cmd = cmdInt & 0x7;
    final count = cmdInt >> 3;
    if (cmd == _cmdMoveTo || cmd == _cmdLineTo) {
      if (i + count * 2 > geom.length) {
        throw const FormatException('truncated MVT geometry');
      }
      if (cmd == _cmdMoveTo && type != MvtGeomType.point) {
        parts.add(<MvtPoint>[]);
      } else if (cmd == _cmdMoveTo && type == MvtGeomType.point && parts.isEmpty) {
        parts.add(<MvtPoint>[]);
      }
      if (parts.isEmpty) parts.add(<MvtPoint>[]);
      final target = parts.last;
      for (int k = 0; k < count; k++) {
        cx += _zigzagDecode(geom[i++]);
        cy += _zigzagDecode(geom[i++]);
        target.add(MvtPoint(cx, cy));
      }
    } else if (cmd == _cmdClosePath) {
      // ring closure; no coordinates follow
    } else {
      throw FormatException('unknown MVT geometry command $cmd');
    }
  }
  return parts;
}

// ---------------------------------------------------------------------------
// Feature / layer / tile encoding
// ---------------------------------------------------------------------------

Uint8List _encodeFeature(MvtFeature f, Map<String, int> keyIndex,
    Map<int, int> valueIndex, List<String> keys, List<Object?> values) {
  final w = _PbWriter();
  if (f.id != 0) w.writeVarintField(1, f.id);
  if (f.properties.isNotEmpty) {
    final tags = <int>[];
    f.properties.forEach((k, v) {
      final ki = keyIndex.putIfAbsent(k, () {
        keys.add(k);
        return keys.length - 1;
      });
      final vh = _valueHash(v);
      final vi = valueIndex.putIfAbsent(vh, () {
        values.add(v);
        return values.length - 1;
      });
      tags.add(ki);
      tags.add(vi);
    });
    w.writePackedVarints(2, tags);
  }
  w.writeVarintField(3, f.type.code);
  w.writePackedVarints(4, _encodeGeometry(f));
  return w.takeBytes();
}

int _valueHash(Object? v) => Object.hash(v, v.runtimeType);

MvtFeature _decodeFeature(Uint8List bytes, List<String> keys, List<Object?> values) {
  final r = _PbReader(bytes);
  final f = MvtFeature(type: MvtGeomType.unknown);
  List<int>? tagIdx;
  List<int>? geom;
  while (!r.eof) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 1:
        f.id = r.readRawVarint();
      case 2:
        final packed = _PbReader(r.readBytes());
        tagIdx = <int>[];
        while (!packed.eof) {
          tagIdx.add(packed.readRawVarint());
        }
      case 3:
        f.type = MvtGeomType.fromCode(r.readRawVarint());
      case 4:
        final packed = _PbReader(r.readBytes());
        geom = <int>[];
        while (!packed.eof) {
          geom.add(packed.readRawVarint());
        }
      default:
        r.skip(wire);
    }
  }
  if (tagIdx != null) {
    for (int i = 0; i + 1 < tagIdx.length; i += 2) {
      final k = keys[tagIdx[i]];
      final v = values[tagIdx[i + 1]];
      f.properties[k] = v;
    }
  }
  f.parts = geom == null ? <List<MvtPoint>>[] : _decodeGeometry(f.type, geom);
  return f;
}

Uint8List encodeMvtLayer(MvtLayer layer) {
  final keys = <String>[];
  final values = <Object?>[];
  final keyIndex = <String, int>{};
  final valueIndex = <int, int>{};

  final w = _PbWriter();
  w.writeVarintField(15, 2); // version
  w.writeStringField(1, layer.name);
  for (final f in layer.features) {
    w.writeBytesField(2, _encodeFeature(f, keyIndex, valueIndex, keys, values));
  }
  for (final k in keys) {
    w.writeStringField(3, k);
  }
  for (final v in values) {
    w.writeBytesField(4, _encodeValue(v));
  }
  if (layer.extent != mvtDefaultExtent) {
    w.writeVarintField(5, layer.extent);
  }
  return w.takeBytes();
}

MvtLayer decodeMvtLayer(Uint8List bytes) {
  final r = _PbReader(bytes);
  String name = '';
  int extent = mvtDefaultExtent;
  final featureBlobs = <Uint8List>[];
  final keys = <String>[];
  final values = <Object?>[];
  while (!r.eof) {
    final (field, wire) = r.readTag();
    switch (field) {
      case 15:
        r.readRawVarint(); // version
      case 1:
        name = r.readString();
      case 2:
        featureBlobs.add(r.readBytes());
      case 3:
        keys.add(r.readString());
      case 4:
        values.add(_decodeValue(r.readBytes()));
      case 5:
        extent = r.readRawVarint();
      default:
        r.skip(wire);
    }
  }
  final layer = MvtLayer(name, extent: extent);
  for (final blob in featureBlobs) {
    layer.features.add(_decodeFeature(blob, keys, values));
  }
  return layer;
}

/// Encode a full MVT tile (one or more layers) to protobuf bytes.
Uint8List encodeMvtTile(List<MvtLayer> layers) {
  final w = _PbWriter();
  for (final layer in layers) {
    w.writeBytesField(3, encodeMvtLayer(layer));
  }
  return w.takeBytes();
}

/// Decode MVT tile bytes into layers.
List<MvtLayer> decodeMvtTile(Uint8List bytes) {
  final r = _PbReader(bytes);
  final layers = <MvtLayer>[];
  while (!r.eof) {
    final (field, wire) = r.readTag();
    if (field == 3) {
      layers.add(decodeMvtLayer(r.readBytes()));
    } else {
      r.skip(wire);
    }
  }
  return layers;
}
