/// Streaming .osm.pbf reader (SPEC §3.1).
///
/// Implements the OSM PBF framing (length-prefixed BlobHeader + Blob),
/// zlib decompression via dart:io [ZLibDecoder], and PrimitiveBlock decoding
/// (string table, granularity/offset, dense nodes with delta coding, ways,
/// turn-restriction relations).
library pbf_reader;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'osm_data.dart';
import 'proto.dart';

/// Visitor callbacks invoked while streaming through a PBF file. Any callback
/// may be null. Enables two-pass / streaming consumers that do not want to
/// materialize a full [OsmData].
class OsmVisitor {
  final void Function(OsmNode node)? onNode;
  final void Function(OsmWay way)? onWay;
  final void Function(TurnRestriction restriction)? onRestriction;

  const OsmVisitor({this.onNode, this.onWay, this.onRestriction});
}

/// Reads the whole file into an [OsmData] (uses [streamOsmPbf] internally).
Future<OsmData> readOsmPbf(String path) async {
  final data = OsmData();
  await streamOsmPbf(
    path,
    OsmVisitor(
      onNode: (n) => data.nodes[n.id] = n,
      onWay: (w) => data.ways[w.id] = w,
      onRestriction: data.restrictions.add,
    ),
  );
  return data;
}

/// Streams blobs of an .osm.pbf file, invoking [visitor] per element.
/// Relations are skipped except turn restrictions (`type=restriction`).
Future<void> streamOsmPbf(String path, OsmVisitor visitor) async {
  final file = File(path);
  if (!await file.exists()) {
    throw FileSystemException('PBF file not found', path);
  }
  final raf = await file.open();
  try {
    final len = await raf.length();
    var offset = 0;
    while (offset < len) {
      // 4-byte big-endian header length.
      final lenBuf = await raf.read(4);
      if (lenBuf.length < 4) break;
      offset += 4;
      final headerLen =
          ByteData.sublistView(lenBuf).getUint32(0, Endian.big);
      if (headerLen <= 0 || headerLen > 64 * 1024) {
        throw FormatException('bad BlobHeader length $headerLen at $offset');
      }
      final headerBuf = await raf.read(headerLen);
      if (headerBuf.length < headerLen) {
        throw const FormatException('truncated BlobHeader');
      }
      offset += headerLen;
      String? type;
      int? dataSize;
      final hr = ProtoReader(headerBuf);
      while (hr.hasMore) {
        final (field, wire) = hr.readKey();
        if (field == 1 && wire == WireType.lengthDelimited) {
          type = hr.readString();
        } else if (field == 3 && wire == WireType.varint) {
          dataSize = hr.readVarint();
        } else {
          hr.skip(wire);
        }
      }
      if (type == null || dataSize == null) {
        throw const FormatException('BlobHeader missing type/datasize');
      }
      final blobBuf = await raf.read(dataSize);
      if (blobBuf.length < dataSize) {
        throw const FormatException('truncated Blob');
      }
      offset += dataSize;
      final raw = _decodeBlob(blobBuf);
      if (type == 'OSMData') {
        _decodePrimitiveBlock(raw, visitor);
      }
      // OSMHeader and unknown types are ignored.
    }
  } finally {
    await raf.close();
  }
}

Uint8List _decodeBlob(Uint8List blob) {
  final r = ProtoReader(blob);
  Uint8List? raw;
  Uint8List? zlibData;
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    if (field == 1 && wire == WireType.lengthDelimited) {
      raw = r.readBytes();
    } else if (field == 3 && wire == WireType.lengthDelimited) {
      zlibData = r.readBytes();
    } else {
      r.skip(wire);
    }
  }
  if (raw != null) return raw;
  if (zlibData != null) {
    return Uint8List.fromList(ZLibDecoder().convert(zlibData));
  }
  throw const FormatException(
      'Blob has neither raw nor zlib_data (lzma/zstd unsupported)');
}

void _decodePrimitiveBlock(Uint8List block, OsmVisitor visitor) {
  final r = ProtoReader(block);
  List<String> stringTable = const [];
  var granularity = 100;
  var latOffset = 0;
  var lonOffset = 0;
  final groups = <Uint8List>[];
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    if (field == 1 && wire == WireType.lengthDelimited) {
      stringTable = _decodeStringTable(r.readBytes());
    } else if (field == 2 && wire == WireType.lengthDelimited) {
      groups.add(r.readBytes());
    } else if (field == 17 && wire == WireType.varint) {
      granularity = r.readVarint();
    } else if (field == 19 && wire == WireType.varint) {
      latOffset = r.readVarint();
    } else if (field == 20 && wire == WireType.varint) {
      lonOffset = r.readVarint();
    } else {
      r.skip(wire);
    }
  }

  double toLat(int raw) => 1e-9 * (latOffset + granularity * raw);
  double toLon(int raw) => 1e-9 * (lonOffset + granularity * raw);

  for (final g in groups) {
    _decodePrimitiveGroup(g, stringTable, toLat, toLon, visitor);
  }
}

List<String> _decodeStringTable(Uint8List bytes) {
  final r = ProtoReader(bytes);
  final out = <String>[];
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    if (field == 1 && wire == WireType.lengthDelimited) {
      out.add(r.readString());
    } else {
      r.skip(wire);
    }
  }
  return out;
}

Map<String, String> _tagsFrom(List<int> keys, List<int> vals, List<String> st) {
  final n = keys.length < vals.length ? keys.length : vals.length;
  if (n == 0) return const {};
  final out = <String, String>{};
  for (var i = 0; i < n; i++) {
    out[st[keys[i]]] = st[vals[i]];
  }
  return out;
}

void _decodePrimitiveGroup(
  Uint8List group,
  List<String> st,
  double Function(int) toLat,
  double Function(int) toLon,
  OsmVisitor visitor,
) {
  final r = ProtoReader(group);
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    if (wire != WireType.lengthDelimited) {
      r.skip(wire);
      continue;
    }
    switch (field) {
      case 1: // Node
        if (visitor.onNode != null) {
          visitor.onNode!(_decodeNode(r.readBytes(), st, toLat, toLon));
        } else {
          r.skip(wire);
        }
        break;
      case 2: // DenseNodes
        if (visitor.onNode != null) {
          _decodeDenseNodes(r.readBytes(), st, toLat, toLon, visitor.onNode!);
        } else {
          r.skip(wire);
        }
        break;
      case 3: // Way
        if (visitor.onWay != null) {
          visitor.onWay!(_decodeWay(r.readBytes(), st));
        } else {
          r.skip(wire);
        }
        break;
      case 4: // Relation
        if (visitor.onRestriction != null) {
          final tr = _decodeRelation(r.readBytes(), st);
          if (tr != null) visitor.onRestriction!(tr);
        } else {
          r.skip(wire);
        }
        break;
      default:
        r.skip(wire);
    }
  }
}

OsmNode _decodeNode(
  Uint8List bytes,
  List<String> st,
  double Function(int) toLat,
  double Function(int) toLon,
) {
  final r = ProtoReader(bytes);
  var id = 0;
  var lat = 0, lon = 0;
  List<int> keys = const [], vals = const [];
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    switch (field) {
      case 1:
        id = r.readSint64();
        break;
      case 2:
        keys = wire == WireType.lengthDelimited
            ? r.readPackedVarint()
            : [r.readVarint()];
        break;
      case 3:
        vals = wire == WireType.lengthDelimited
            ? r.readPackedVarint()
            : [r.readVarint()];
        break;
      case 8:
        lat = r.readSint64();
        break;
      case 9:
        lon = r.readSint64();
        break;
      default:
        r.skip(wire);
    }
  }
  return OsmNode(id, toLat(lat), toLon(lon), _tagsFrom(keys, vals, st));
}

void _decodeDenseNodes(
  Uint8List bytes,
  List<String> st,
  double Function(int) toLat,
  double Function(int) toLon,
  void Function(OsmNode) onNode,
) {
  final r = ProtoReader(bytes);
  List<int> ids = const [], lats = const [], lons = const [], keysVals = const [];
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    if (wire != WireType.lengthDelimited) {
      r.skip(wire);
      continue;
    }
    switch (field) {
      case 1:
        ids = r.readPackedSint64();
        break;
      case 8:
        lats = r.readPackedSint64();
        break;
      case 9:
        lons = r.readPackedSint64();
        break;
      case 10:
        keysVals = r.readPackedVarint();
        break;
      default:
        r.skip(wire);
    }
  }
  var id = 0, lat = 0, lon = 0;
  var kv = 0;
  final wantTags = keysVals.isNotEmpty;
  for (var i = 0; i < ids.length; i++) {
    id += ids[i];
    lat += i < lats.length ? lats[i] : 0;
    lon += i < lons.length ? lons[i] : 0;
    Map<String, String> tags = const {};
    if (wantTags) {
      // Pairs of (key, val) string-table ids, terminated by 0.
      if (kv < keysVals.length && keysVals[kv] != 0) {
        tags = <String, String>{};
        while (kv < keysVals.length && keysVals[kv] != 0) {
          final k = keysVals[kv];
          final v = kv + 1 < keysVals.length ? keysVals[kv + 1] : 0;
          kv += 2;
          tags[st[k]] = st[v];
        }
      }
      if (kv < keysVals.length && keysVals[kv] == 0) kv++; // consume terminator
    }
    onNode(OsmNode(id, toLat(lat), toLon(lon), tags));
  }
}

OsmWay _decodeWay(Uint8List bytes, List<String> st) {
  final r = ProtoReader(bytes);
  var id = 0;
  List<int> keys = const [], vals = const [], refDeltas = const [];
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    switch (field) {
      case 1:
        id = r.readVarint();
        break;
      case 2:
        keys = wire == WireType.lengthDelimited
            ? r.readPackedVarint()
            : [r.readVarint()];
        break;
      case 3:
        vals = wire == WireType.lengthDelimited
            ? r.readPackedVarint()
            : [r.readVarint()];
        break;
      case 8:
        refDeltas = r.readPackedSint64();
        break;
      default:
        r.skip(wire);
    }
  }
  final refs = List<int>.filled(refDeltas.length, 0);
  var acc = 0;
  for (var i = 0; i < refDeltas.length; i++) {
    acc += refDeltas[i];
    refs[i] = acc;
  }
  return OsmWay(id, refs, _tagsFrom(keys, vals, st));
}

/// Decodes a Relation; returns a [TurnRestriction] when it is a via-node
/// turn restriction, else null (all other relations are skipped).
TurnRestriction? _decodeRelation(Uint8List bytes, List<String> st) {
  final r = ProtoReader(bytes);
  List<int> keys = const [], vals = const [], rolesSid = const [],
      memDeltas = const [], types = const [];
  while (r.hasMore) {
    final (field, wire) = r.readKey();
    switch (field) {
      case 2:
        keys = wire == WireType.lengthDelimited
            ? r.readPackedVarint()
            : [r.readVarint()];
        break;
      case 3:
        vals = wire == WireType.lengthDelimited
            ? r.readPackedVarint()
            : [r.readVarint()];
        break;
      case 8:
        rolesSid = r.readPackedVarint();
        break;
      case 9:
        memDeltas = r.readPackedSint64();
        break;
      case 10:
        types = r.readPackedVarint();
        break;
      default:
        r.skip(wire);
    }
  }
  final tags = _tagsFrom(keys, vals, st);
  if (tags['type'] != 'restriction') return null;
  final restriction = tags['restriction'];
  if (restriction == null) return null;
  final type = restrictionTypeFromString(restriction);
  if (type == null) return null;

  int? fromWay, toWay, viaNode;
  var acc = 0;
  final n = memDeltas.length;
  for (var i = 0; i < n; i++) {
    acc += memDeltas[i];
    final role = i < rolesSid.length ? st[rolesSid[i]] : '';
    final memberType = i < types.length ? types[i] : 0; // 0=node,1=way
    if (role == 'from' && memberType == 1) {
      fromWay = acc;
    } else if (role == 'to' && memberType == 1) {
      toWay = acc;
    } else if (role == 'via' && memberType == 0) {
      viaNode = acc;
    } else if (role == 'via' && memberType == 1) {
      return null; // via-way restrictions unsupported by the data model
    }
  }
  if (fromWay == null || toWay == null || viaNode == null) return null;
  return TurnRestriction(fromWay, viaNode, toWay, type);
}
