/// Routing graph with compressed adjacency, binary v1 serialization and a
/// grid nearest-node index (SPEC §3.2).
library routing_graph;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pbf/osm_data.dart';
import '../router/exceptions.dart';

Uint8List utf8Encode(String s) => Uint8List.fromList(utf8.encode(s));

String utf8Decode(Uint8List bytes, int start, int end) =>
    utf8.decode(Uint8List.sublistView(bytes, start, end));

/// One stored turn restriction in graph-local indices.
class GraphTurnRestriction {
  final int viaNode; // node index
  final int fromWay; // way-table index
  final int toWay; // way-table index
  final int type; // RestrictionType.index
  const GraphTurnRestriction(this.viaNode, this.fromWay, this.toWay, this.type);
}

class RoutingGraph {
  // --- nodes ---------------------------------------------------------------
  late Float64List nodeLat;
  late Float64List nodeLon;

  // --- directed edges (compressed adjacency) --------------------------------
  // Out-adjacency: for node i, out edge ids are
  // [outOffset[i], outOffset[i+1]) into the edge arrays.
  late Int32List outOffset;
  late Int32List _edgeSource;
  late Int32List _edgeTarget;
  late Float32List _edgeDist;
  late Int32List _edgeWayIdx;
  // In-adjacency: for node i, in edge ids (edges whose target is i).
  late Int32List inOffset;
  late Int32List inEdgeIds;

  // --- way table -------------------------------------------------------------
  late Int64List wayIds; // original OSM way ids
  /// OSM tags per way-table index (drives per-profile lazy cost factors).
  List<Map<String, String>> wayTags = [];

  /// Display name of way-table entry [i] (name or ref tag), if any.
  String? wayName(int i) {
    final t = wayTags[i];
    return t['name'] ?? t['ref'];
  }

  // --- turn restrictions -------------------------------------------------------
  /// viaNode index -> restrictions at that node.
  Map<int, List<GraphTurnRestriction>> restrictions = {};

  // --- grid index --------------------------------------------------------------
  static const double _gridCellDeg = 0.005; // ~500 m cells
  double _gridMinLat = 0, _gridMinLon = 0;
  int _gridRows = 0, _gridCols = 0;
  List<List<int>> _grid = [];

  int get nodeCount => nodeLat.length;
  int get edgeCount => _edgeTarget.length;

  /// Outgoing edge ids of [node].
  List<int> edgesOf(int node) {
    final s = outOffset[node];
    final e = outOffset[node + 1];
    return List<int>.generate(e - s, (i) => s + i);
  }

  /// Incoming edge ids of [node] (edges whose target is [node]).
  List<int> inEdgesOf(int node) {
    final s = inOffset[node];
    final e = inOffset[node + 1];
    return inEdgeIds.sublist(s, e);
  }

  int edgeSourceOf(int edge) => _edgeSource[edge];

  // SPEC §3.2 accessors.
  int edgeTarget(int edge) => _edgeTarget[edge];
  double edgeDistM(int edge) => _edgeDist[edge];

  /// Original OSM way id of [edge].
  int edgeWay(int edge) => wayIds[_edgeWayIdx[edge]];

  /// Way-table index of [edge] (used for turn restriction checks).
  int edgeWayIndex(int edge) => _edgeWayIdx[edge];

  double nodeLatOf(int node) => nodeLat[node];
  double nodeLonOf(int node) => nodeLon[node];

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  /// Builds a graph from [osm], keeping only ways where [isRoutable] holds.
  /// Every node referenced by a kept way becomes a graph node; edges are the
  /// per-segment pairs of consecutive node refs. Oneway (-1/reversible) and
  /// junction=roundabout handling per BRouter semantics.
  static RoutingGraph build(OsmData osm,
      {required bool Function(OsmWay) isRoutable}) {
    final g = RoutingGraph();
    final nodeIndex = <int, int>{}; // osm node id -> graph node idx
    final wayIndex = <int, int>{}; // osm way id -> way-table idx
    final wayIds = <int>[];
    final wayTags = <Map<String, String>>[];

    // First pass: assign node indices for nodes used by routable ways.
    final keptWays = <OsmWay>[];
    for (final w in osm.ways.values) {
      if (!isRoutable(w)) continue;
      if (w.nodeRefs.length < 2) continue;
      keptWays.add(w);
      for (final ref in w.nodeRefs) {
        if (osm.nodes.containsKey(ref)) {
          nodeIndex.putIfAbsent(ref, () => nodeIndex.length);
        }
      }
    }

    g.nodeLat = Float64List(nodeIndex.length);
    g.nodeLon = Float64List(nodeIndex.length);
    nodeIndex.forEach((osmId, idx) {
      final n = osm.nodes[osmId]!;
      g.nodeLat[idx] = n.lat;
      g.nodeLon[idx] = n.lon;
    });

    // Second pass: edges.
    final src = <int>[];
    final dst = <int>[];
    final dist = <double>[];
    final wayIdx = <int>[];

    int wayTableIndex(OsmWay w) {
      var i = wayIndex[w.id];
      if (i == null) {
        i = wayIds.length;
        wayIndex[w.id] = i;
        wayIds.add(w.id);
        wayTags.add(Map<String, String>.unmodifiable(w.tags));
      }
      return i;
    }

    for (final w in keptWays) {
      final oneway = onewayDirection(w.tags);
      final wi = wayTableIndex(w);
      for (var i = 0; i + 1 < w.nodeRefs.length; i++) {
        final a = nodeIndex[w.nodeRefs[i]];
        final b = nodeIndex[w.nodeRefs[i + 1]];
        if (a == null || b == null) continue; // dangling ref
        if (a == b) continue;
        final d = _dist(g.nodeLat[a], g.nodeLon[a], g.nodeLat[b], g.nodeLon[b]);
        if (oneway >= 0) {
          src.add(a);
          dst.add(b);
          dist.add(d);
          wayIdx.add(wi);
        }
        if (oneway <= 0) {
          src.add(b);
          dst.add(a);
          dist.add(d);
          wayIdx.add(wi);
        }
      }
    }

    _buildAdjacency(g, nodeIndex.length, src, dst, dist, wayIdx);
    g.wayIds = Int64List.fromList(wayIds);
    g.wayTags = wayTags;

    // Turn restrictions (only those whose ways/nodes survived the filter).
    for (final tr in osm.restrictions) {
      final via = nodeIndex[tr.viaNode];
      final from = wayIndex[tr.fromWay];
      final to = wayIndex[tr.toWay];
      if (via == null || from == null || to == null) continue;
      g.restrictions
          .putIfAbsent(via, () => [])
          .add(GraphTurnRestriction(via, from, to, tr.type.index));
    }

    g._buildGrid();
    return g;
  }

  static void _buildAdjacency(RoutingGraph g, int nodeCount, List<int> src,
      List<int> dst, List<double> dist, List<int> wayIdx) {
    final m = src.length;
    g._edgeSource = Int32List.fromList(src);
    g._edgeTarget = Int32List.fromList(dst);
    g._edgeDist = Float32List.fromList(dist);
    g._edgeWayIdx = Int32List.fromList(wayIdx);

    // Out adjacency (edges are already grouped by source? not necessarily —
    // sort edge ids by source).
    final order = List<int>.generate(m, (i) => i)
      ..sort((a, b) => src[a] != src[b]
          ? src[a] - src[b]
          : dst[a] - dst[b]);
    g.outOffset = Int32List(nodeCount + 1);
    final sortedSrc = Int32List(m);
    final sortedDst = Int32List(m);
    final sortedDist = Float32List(m);
    final sortedWay = Int32List(m);
    for (var i = 0; i < m; i++) {
      final e = order[i];
      sortedSrc[i] = src[e];
      sortedDst[i] = dst[e];
      sortedDist[i] = dist[e];
      sortedWay[i] = wayIdx[e];
    }
    g._edgeSource = sortedSrc;
    g._edgeTarget = sortedDst;
    g._edgeDist = sortedDist;
    g._edgeWayIdx = sortedWay;
    for (var i = 0; i < m; i++) {
      g.outOffset[sortedSrc[i] + 1]++;
    }
    for (var i = 0; i < nodeCount; i++) {
      g.outOffset[i + 1] += g.outOffset[i];
    }

    // In adjacency.
    g.inOffset = Int32List(nodeCount + 1);
    for (var i = 0; i < m; i++) {
      g.inOffset[sortedDst[i] + 1]++;
    }
    for (var i = 0; i < nodeCount; i++) {
      g.inOffset[i + 1] += g.inOffset[i];
    }
    g.inEdgeIds = Int32List(m);
    final cursor = Int32List.fromList(g.inOffset);
    for (var i = 0; i < m; i++) {
      g.inEdgeIds[cursor[sortedDst[i]]++] = i;
    }
  }

  /// BRouter oneway semantics: returns 1 = forward only, -1 = backward only,
  /// 0 = both directions. junction=roundabout forces forward-oneway.
  static int onewayDirection(Map<String, String> tags) {
    if (tags['junction'] == 'roundabout') return 1;
    final ow = tags['oneway'] ?? tags['oneway:bicycle'];
    if (ow == null) return 0;
    if (ow == '-1' || ow == 'reverse') return -1;
    if (ow == 'yes' || ow == 'true' || ow == '1') return 1;
    // 'reversible' (alternating direction over time) is treated as
    // both-directions for routing, matching BRouter behaviour.
    return 0;
  }

  static double _dist(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dp = (lat2 - lat1) * math.pi / 180;
    final dl = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  // ---------------------------------------------------------------------------
  // Grid nearest-node index
  // ---------------------------------------------------------------------------

  void _buildGrid() {
    if (nodeCount == 0) {
      _grid = [];
      return;
    }
    var minLat = nodeLat[0], maxLat = nodeLat[0];
    var minLon = nodeLon[0], maxLon = nodeLon[0];
    for (var i = 1; i < nodeCount; i++) {
      minLat = math.min(minLat, nodeLat[i]);
      maxLat = math.max(maxLat, nodeLat[i]);
      minLon = math.min(minLon, nodeLon[i]);
      maxLon = math.max(maxLon, nodeLon[i]);
    }
    _gridMinLat = minLat - 1e-9;
    _gridMinLon = minLon - 1e-9;
    _gridRows = ((maxLat - _gridMinLat) / _gridCellDeg).ceil() + 1;
    _gridCols = ((maxLon - _gridMinLon) / _gridCellDeg).ceil() + 1;
    _grid = List.generate(_gridRows * _gridCols, (_) => <int>[]);
    for (var i = 0; i < nodeCount; i++) {
      _grid[_cellOf(nodeLat[i], nodeLon[i])].add(i);
    }
  }

  int _cellOf(double lat, double lon) {
    var r = ((lat - _gridMinLat) / _gridCellDeg).floor();
    var c = ((lon - _gridMinLon) / _gridCellDeg).floor();
    r = r.clamp(0, _gridRows - 1);
    c = c.clamp(0, _gridCols - 1);
    return r * _gridCols + c;
  }

  /// Nearest node by expanding ring search over the grid; O(1)-ish for
  /// queries near the network. Throws [NoRouteException] on an empty graph.
  int nearestNode(double lat, double lon) {
    if (nodeCount == 0) {
      throw NoRouteException('graph is empty');
    }
    if (_grid.isEmpty) _buildGrid();
    var best = -1;
    var bestD = double.infinity;

    void scanCell(int r, int c) {
      if (r < 0 || c < 0 || r >= _gridRows || c >= _gridCols) return;
      for (final n in _grid[r * _gridCols + c]) {
        final d = _dist(lat, lon, nodeLat[n], nodeLon[n]);
        if (d < bestD) {
          bestD = d;
          best = n;
        }
      }
    }

    final cr = ((lat - _gridMinLat) / _gridCellDeg).floor();
    final cc = ((lon - _gridMinLon) / _gridCellDeg).floor();
    // Expanding square rings; once a hit exists and the ring's inner edge is
    // farther than bestD, the search can stop.
    final cellMeters = _gridCellDeg * 111320.0;
    for (var ring = 0; ring < math.max(_gridRows, _gridCols) + 1; ring++) {
      final r0 = cr - ring, r1 = cr + ring;
      final c0 = cc - ring, c1 = cc + ring;
      for (var c = c0; c <= c1; c++) {
        scanCell(r0, c);
        if (r1 != r0) scanCell(r1, c);
      }
      for (var r = r0 + 1; r < r1; r++) {
        scanCell(r, c0);
        if (c1 != c0) scanCell(r, c1);
      }
      if (best >= 0 && (ring - 1) * cellMeters > bestD) break;
    }
    if (best < 0) {
      // Fallback: brute force (query far outside grid with clamped cells).
      for (var i = 0; i < nodeCount; i++) {
        final d = _dist(lat, lon, nodeLat[i], nodeLon[i]);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Binary serialization, format v1 ("RGB1")
  // ---------------------------------------------------------------------------

  static const int formatVersion = 1;

  void serializeTo(String path) {
    final out = BytesBuilder(copy: false);
    void i32(int v) {
      final bd = ByteData(4)..setInt32(0, v, Endian.little);
      out.add(bd.buffer.asUint8List());
    }

    void i64(int v) {
      final bd = ByteData(8)..setInt64(0, v, Endian.little);
      out.add(bd.buffer.asUint8List());
    }

    void f64(double v) {
      final bd = ByteData(8)..setFloat64(0, v, Endian.little);
      out.add(bd.buffer.asUint8List());
    }

    void f32(double v) {
      final bd = ByteData(4)..setFloat32(0, v, Endian.little);
      out.add(bd.buffer.asUint8List());
    }

    out.add('RGB1'.codeUnits);
    i32(formatVersion);

    // nodes
    i32(nodeCount);
    for (var i = 0; i < nodeCount; i++) {
      f64(nodeLat[i]);
    }
    for (var i = 0; i < nodeCount; i++) {
      f64(nodeLon[i]);
    }

    // edges
    final m = edgeCount;
    i32(m);
    for (var i = 0; i <= nodeCount; i++) {
      i32(outOffset[i]);
    }
    for (var i = 0; i < m; i++) {
      i32(_edgeSource[i]);
    }
    for (var i = 0; i < m; i++) {
      i32(_edgeTarget[i]);
    }
    for (var i = 0; i < m; i++) {
      f32(_edgeDist[i]);
    }
    for (var i = 0; i < m; i++) {
      i32(_edgeWayIdx[i]);
    }

    // way table
    i32(wayIds.length);
    for (var i = 0; i < wayIds.length; i++) {
      i64(wayIds[i]);
    }
    // way tags via string pool
    final pool = <String, int>{};
    final poolStrings = <String>[];
    int poolIndex(String s) {
      var i = pool[s];
      if (i == null) {
        i = poolStrings.length;
        pool[s] = i;
        poolStrings.add(s);
      }
      return i;
    }

    final tagIdx = <List<int>>[]; // per way: flattened [k,v,k,v,...] pool ids
    for (final tags in wayTags) {
      final flat = <int>[];
      tags.forEach((k, v) {
        flat.add(poolIndex(k));
        flat.add(poolIndex(v));
      });
      tagIdx.add(flat);
    }
    i32(poolStrings.length);
    for (final s in poolStrings) {
      final b = utf8Encode(s);
      i32(b.length);
      out.add(b);
    }
    i32(wayTags.length);
    for (final flat in tagIdx) {
      i32(flat.length ~/ 2);
      for (final i in flat) {
        i32(i);
      }
    }

    // restrictions
    final all = <GraphTurnRestriction>[
      for (final l in restrictions.values) ...l
    ];
    i32(all.length);
    for (final r in all) {
      i32(r.viaNode);
      i32(r.fromWay);
      i32(r.toWay);
      i32(r.type);
    }

    File(path).writeAsBytesSync(out.takeBytes());
  }

  static RoutingGraph loadFrom(String path) {
    final bytes = File(path).readAsBytesSync();
    final bd = ByteData.sublistView(bytes);
    var pos = 0;

    int i32() {
      final v = bd.getInt32(pos, Endian.little);
      pos += 4;
      return v;
    }

    int i64() {
      final v = bd.getInt64(pos, Endian.little);
      pos += 8;
      return v;
    }

    double f64() {
      final v = bd.getFloat64(pos, Endian.little);
      pos += 8;
      return v;
    }

    double f32() {
      final v = bd.getFloat32(pos, Endian.little);
      pos += 4;
      return v;
    }

    if (bytes.length < 8 ||
        bytes[0] != 0x52 || // R
        bytes[1] != 0x47 || // G
        bytes[2] != 0x42 || // B
        bytes[3] != 0x31) {
      // 1
      throw const FormatException('not a graph.bin RGB1 file');
    }
    pos = 4;
    final version = i32();
    if (version != formatVersion) {
      throw FormatException('unsupported graph.bin version $version');
    }

    final g = RoutingGraph();
    final n = i32();
    g.nodeLat = Float64List(n);
    g.nodeLon = Float64List(n);
    for (var i = 0; i < n; i++) {
      g.nodeLat[i] = f64();
    }
    for (var i = 0; i < n; i++) {
      g.nodeLon[i] = f64();
    }

    final m = i32();
    g.outOffset = Int32List(n + 1);
    for (var i = 0; i <= n; i++) {
      g.outOffset[i] = i32();
    }
    g._edgeSource = Int32List(m);
    g._edgeTarget = Int32List(m);
    g._edgeDist = Float32List(m);
    g._edgeWayIdx = Int32List(m);
    for (var i = 0; i < m; i++) {
      g._edgeSource[i] = i32();
    }
    for (var i = 0; i < m; i++) {
      g._edgeTarget[i] = i32();
    }
    for (var i = 0; i < m; i++) {
      g._edgeDist[i] = f32();
    }
    for (var i = 0; i < m; i++) {
      g._edgeWayIdx[i] = i32();
    }

    final wcount = i32();
    g.wayIds = Int64List(wcount);
    for (var i = 0; i < wcount; i++) {
      g.wayIds[i] = i64();
    }
    final pcount = i32();
    final pool = List<String>.filled(pcount, '');
    for (var i = 0; i < pcount; i++) {
      final len = i32();
      pool[i] = utf8Decode(bytes, pos, pos + len);
      pos += len;
    }
    final tcount = i32();
    g.wayTags = List.generate(tcount, (_) => <String, String>{});
    for (var i = 0; i < tcount; i++) {
      final nTags = i32();
      final tags = <String, String>{};
      for (var j = 0; j < nTags; j++) {
        tags[pool[i32()]] = pool[i32()];
      }
      g.wayTags[i] = Map<String, String>.unmodifiable(tags);
    }

    final rcount = i32();
    g.restrictions = {};
    for (var i = 0; i < rcount; i++) {
      final r = GraphTurnRestriction(i32(), i32(), i32(), i32());
      g.restrictions.putIfAbsent(r.viaNode, () => []).add(r);
    }

    g._rebuildInAdjacency();
    g._buildGrid();
    return g;
  }

  /// Rebuilds the in-adjacency index from the edge arrays (used after load).
  void _rebuildInAdjacency() {
    final m = edgeCount;
    inOffset = Int32List(nodeCount + 1);
    for (var i = 0; i < m; i++) {
      inOffset[_edgeTarget[i] + 1]++;
    }
    for (var i = 0; i < nodeCount; i++) {
      inOffset[i + 1] += inOffset[i];
    }
    inEdgeIds = Int32List(m);
    final cursor = Int32List.fromList(inOffset);
    for (var i = 0; i < m; i++) {
      inEdgeIds[cursor[_edgeTarget[i]]++] = i;
    }
  }
}
