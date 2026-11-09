/// Synthetic .osm.pbf WRITER (test fixture, SPEC §8).
///
/// Produces real PBF framing (BlobHeader/Blob, zlib-compressed
/// PrimitiveBlocks, string tables, dense nodes with delta coding, ways,
/// relations) so the reader in lib/src/pbf is proven by round-trips.
library pbf_writer_fixture;

import 'dart:io';
import 'dart:typed_data';

import '../src/pbf/proto.dart';

class PbfNode {
  final int id;
  final double lat;
  final double lon;
  final Map<String, String> tags;
  const PbfNode(this.id, this.lat, this.lon, [this.tags = const {}]);
}

class PbfWay {
  final int id;
  final List<int> nodeRefs;
  final Map<String, String> tags;
  const PbfWay(this.id, this.nodeRefs, this.tags);
}

class PbfRelationMember {
  final int id;
  final int type; // 0=node, 1=way, 2=relation
  final String role;
  const PbfRelationMember(this.id, this.type, this.role);
}

class PbfRelation {
  final int id;
  final Map<String, String> tags;
  final List<PbfRelationMember> members;
  const PbfRelation(this.id, this.tags, this.members);
}

/// Writes a complete .osm.pbf file.
void writeOsmPbf(
  String path, {
  required List<PbfNode> nodes,
  required List<PbfWay> ways,
  List<PbfRelation> relations = const [],
}) {
  // --- string table ---------------------------------------------------------
  final pool = <String, int>{};
  final strings = <String>[];
  int sid(String s) {
    var i = pool[s];
    if (i == null) {
      i = strings.length;
      pool[s] = i;
      strings.add(s);
    }
    return i;
  }

  sid(''); // index 0 reserved (matches osmosis convention)
  for (final n in nodes) {
    n.tags.forEach((k, v) {
      sid(k);
      sid(v);
    });
  }
  for (final w in ways) {
    w.tags.forEach((k, v) {
      sid(k);
      sid(v);
    });
  }
  for (final r in relations) {
    r.tags.forEach((k, v) {
      sid(k);
      sid(v);
    });
    for (final m in r.members) {
      sid(m.role);
    }
  }

  const granularity = 100;
  const latOffset = 0;
  const lonOffset = 0;
  int raw(double deg) => (deg * 1e9 / granularity).round();

  // --- string table message -------------------------------------------------
  final stw = ProtoWriter();
  for (final s in strings) {
    stw.writeString(1, s);
  }
  final stBytes = stw.takeBytes();

  // --- primitive group --------------------------------------------------------
  final gw = ProtoWriter();

  // DenseNodes
  final dw = ProtoWriter();
  final idDeltas = <int>[], latDeltas = <int>[], lonDeltas = <int>[];
  final keysVals = <int>[];
  var prevId = 0, prevLat = 0, prevLon = 0;
  var anyTags = false;
  for (final n in nodes) {
    idDeltas.add(n.id - prevId);
    prevId = n.id;
    final rl = raw(n.lat), rlo = raw(n.lon);
    latDeltas.add(rl - prevLat);
    prevLat = rl;
    lonDeltas.add(rlo - prevLon);
    prevLon = rlo;
    if (n.tags.isNotEmpty) anyTags = true;
  }
  if (anyTags) {
    for (final n in nodes) {
      n.tags.forEach((k, v) {
        keysVals.add(sid(k));
        keysVals.add(sid(v));
      });
      keysVals.add(0);
    }
  }
  dw.writePackedSint64(1, idDeltas);
  dw.writePackedSint64(8, latDeltas);
  dw.writePackedSint64(9, lonDeltas);
  if (anyTags) dw.writePackedVarint(10, keysVals);
  gw.writeBytes(2, dw.takeBytes());

  // Ways
  for (final w in ways) {
    final ww = ProtoWriter();
    ww.writeVarint(1, w.id);
    if (w.tags.isNotEmpty) {
      ww.writePackedVarint(2, [for (final k in w.tags.keys) sid(k)]);
      ww.writePackedVarint(3, [for (final v in w.tags.values) sid(v)]);
    }
    final deltas = <int>[];
    var prev = 0;
    for (final ref in w.nodeRefs) {
      deltas.add(ref - prev);
      prev = ref;
    }
    ww.writePackedSint64(8, deltas);
    gw.writeBytes(3, ww.takeBytes());
  }

  // Relations
  for (final r in relations) {
    final rw = ProtoWriter();
    rw.writeVarint(1, r.id);
    if (r.tags.isNotEmpty) {
      rw.writePackedVarint(2, [for (final k in r.tags.keys) sid(k)]);
      rw.writePackedVarint(3, [for (final v in r.tags.values) sid(v)]);
    }
    rw.writePackedVarint(8, [for (final m in r.members) sid(m.role)]);
    final deltas = <int>[];
    var prev = 0;
    for (final m in r.members) {
      deltas.add(m.id - prev);
      prev = m.id;
    }
    rw.writePackedSint64(9, deltas);
    rw.writePackedVarint(10, [for (final m in r.members) m.type]);
    gw.writeBytes(4, rw.takeBytes());
  }

  // --- primitive block --------------------------------------------------------
  final bw = ProtoWriter();
  bw.writeBytes(1, stBytes);
  bw.writeBytes(2, gw.takeBytes());
  if (granularity != 100) bw.writeVarint(17, granularity);
  if (latOffset != 0) bw.writeVarint(19, latOffset);
  if (lonOffset != 0) bw.writeVarint(20, lonOffset);
  final dataBlock = bw.takeBytes();

  // --- header block -----------------------------------------------------------
  final hw = ProtoWriter();
  final fb = ProtoWriter();
  fb.writeString(4, 'OsmSchema-V0.6');
  fb.writeString(5, 'DenseNodes');
  hw.writeBytes(4, fb.takeBytes()); // required_features
  hw.writeString(16, 'openride-test-fixture');
  final headerBlock = hw.takeBytes();

  final out = BytesBuilder(copy: false);
  void writeBlob(String type, Uint8List payload) {
    final blob = ProtoWriter();
    final compressed =
        Uint8List.fromList(ZLibEncoder().convert(payload));
    blob.writeVarint(2, payload.length); // raw_size
    blob.writeBytes(3, compressed); // zlib_data
    final blobBytes = blob.takeBytes();

    final bh = ProtoWriter();
    bh.writeString(1, type);
    bh.writeVarint(3, blobBytes.length); // datasize
    final bhBytes = bh.takeBytes();

    final lenBd = ByteData(4)..setUint32(0, bhBytes.length, Endian.big);
    out.add(lenBd.buffer.asUint8List());
    out.add(bhBytes);
    out.add(blobBytes);
  }

  writeBlob('OSMHeader', headerBlock);
  writeBlob('OSMData', dataBlock);
  File(path).writeAsBytesSync(out.takeBytes());
}

// ---------------------------------------------------------------------------
// Fixture generators
// ---------------------------------------------------------------------------

/// An n x n grid city centered at (lat0, lon0) with [stepDeg] spacing.
/// Streets: all grid lines, tagged highway=residential unless overridden.
/// Returns generated ids so tests can reference nodes/ways.
class GridCity {
  final List<PbfNode> nodes = [];
  final List<PbfWay> ways = [];
  final List<PbfRelation> relations = [];
  final int n;
  final double lat0, lon0, stepDeg;

  /// node id at grid coordinate (i = row/lat, j = col/lon), 1-based ids.
  int nodeId(int i, int j) => 1 + i * n + j;

  GridCity(this.n, this.lat0, this.lon0, this.stepDeg,
      {Map<String, String> streetTags = const {'highway': 'residential'},
      Map<int, Map<String, String>>? wayTagOverrides}) {
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        nodes.add(PbfNode(nodeId(i, j), lat0 + i * stepDeg, lon0 + j * stepDeg));
      }
    }
    var wayId = 1;
    // horizontal streets (i-th row)
    for (var i = 0; i < n; i++) {
      ways.add(PbfWay(wayId, [for (var j = 0; j < n; j++) nodeId(i, j)],
          wayTagOverrides?[wayId] ?? streetTags));
      wayId++;
    }
    // vertical streets (j-th col)
    for (var j = 0; j < n; j++) {
      ways.add(PbfWay(wayId, [for (var i = 0; i < n; i++) nodeId(i, j)],
          wayTagOverrides?[wayId] ?? streetTags));
      wayId++;
    }
  }

  double lat(int i, int j) => lat0 + i * stepDeg;
  double lon(int i, int j) => lon0 + j * stepDeg;
}
