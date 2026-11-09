/// Bidirectional A* over edge-pair states with BRouter turn costs and turn
/// restrictions (SPEC §3.4).
library astar;

import 'dart:collection';
import 'dart:math' as math;

import '../graph/routing_graph.dart';
import '../pbf/osm_data.dart' show RestrictionType;
import '../profile/cost_profile.dart';
import 'exceptions.dart';

/// Internal per-request profile context: lazily computed way cost factors and
/// (optionally) per-edge elevation factors.
class ProfileContext {
  final CostProfile profile;
  final RoutingGraph graph;
  final double? Function(int node)? elevationOf; // null => no elevation
  List<double>? _wayFactor; // per way-table index
  Map<int, double>? _edgeEleFactor; // per edge id, computed lazily

  ProfileContext(this.profile, this.graph, this.elevationOf);

  double wayFactor(int wayIdx) {
    final wf = _wayFactor ??= List<double>.filled(graph.wayIds.length, -1);
    var f = wf[wayIdx];
    if (f < 0) {
      f = edgeCostFactor(profile, graph.wayTags[wayIdx]);
      wf[wayIdx] = f;
    }
    return f;
  }

  /// Full per-meter cost factor of an edge (way factor x elevation factor).
  double edgeFactor(int edge) {
    final wf = wayFactor(graph.edgeWayIndex(edge));
    if (wf == double.infinity) return wf;
    final eo = elevationOf;
    if (eo == null) return wf;
    final cache = _edgeEleFactor ??= {};
    final cached = cache[edge];
    if (cached != null) return cached == -1 ? wf : wf * cached;
    final s = graph.edgeSourceOf(edge);
    final t = graph.edgeTarget(edge);
    final e1 = eo(s);
    final e2 = eo(t);
    var f = 1.0;
    if (e1 != null && e2 != null) {
      final d = graph.edgeDistM(edge);
      if (d > 0.5) {
        f = elevationCostFactor(profile, (e2 - e1) / d);
      }
    }
    cache[edge] = f == 1.0 ? -1 : f;
    return wf * f;
  }

  double edgeCostMeters(int edge) => graph.edgeDistM(edge) * edgeFactor(edge);

  /// Time in seconds for an edge, BRouter-style: nominal class speed
  /// degraded by the cost factor.
  double edgeTimeS(int edge) {
    final tags = graph.wayTags[graph.edgeWayIndex(edge)];
    final hw = tags['highway'] ?? 'road';
    final speed = (profile.baseSpeed[hw] ?? 5.0);
    final f = edgeFactor(edge);
    if (f == double.infinity) return double.infinity;
    return graph.edgeDistM(edge) * f / speed;
  }

  /// Lower bound on cost per meter across the profile (for A* heuristic).
  double get minCostPerMeter {
    var m = double.infinity;
    for (final v in profile.highwayCost.values) {
      if (v < m) m = v;
    }
    if (!m.isFinite || m <= 0) m = 1.0;
    // Elevation factor >= 1 and surface factor could go below 1? (ours don't)
    return m * 0.5; // safety margin keeps heuristic admissible
  }
}

/// A found path: ordered list of directed edge ids from start to target.
class FoundPath {
  final List<int> edges; // directed edge ids, start -> target
  final double costMeters;
  FoundPath(this.edges, this.costMeters);
}

class _State {
  final int node;
  final int edge; // incoming edge (forward) / outgoing edge (backward); -1 root
  final double g;
  final double f;
  _State(this.node, this.edge, this.g, this.f);
}

class _MinHeap {
  final List<_State> _h = [];
  bool get isEmpty => _h.isEmpty;
  _State get top => _h.first;

  void push(_State s) {
    _h.add(s);
    var i = _h.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_h[p].f <= _h[i].f) break;
      final tmp = _h[p];
      _h[p] = _h[i];
      _h[i] = tmp;
      i = p;
    }
  }

  _State pop() {
    final out = _h.first;
    final last = _h.removeLast();
    if (_h.isNotEmpty) {
      _h[0] = last;
      var i = 0;
      while (true) {
        var smallest = i;
        final l = 2 * i + 1, r = 2 * i + 2;
        if (l < _h.length && _h[l].f < _h[smallest].f) smallest = l;
        if (r < _h.length && _h[r].f < _h[smallest].f) smallest = r;
        if (smallest == i) break;
        final tmp = _h[i];
        _h[i] = _h[smallest];
        _h[smallest] = tmp;
        i = smallest;
      }
    }
    return out;
  }
}

/// Bidirectional A* router over a [RoutingGraph].
class BiAStar {
  final RoutingGraph g;
  final ProfileContext ctx;

  BiAStar(this.g, this.ctx);

  static int _key(int node, int edge) => node * 0x40000000 + (edge + 1);

  /// True when the turn from edge [e1] (entering [node]) to edge [e2]
  /// (leaving [node]) is allowed under turn restrictions.
  bool _turnAllowed(int node, int e1, int e2) {
    if (e1 < 0 || e2 < 0) return true;
    if (!ctx.profile.considerTurnRestrictions) return true;
    final rs = g.restrictions[node];
    if (rs == null) return true;
    final fw = g.edgeWayIndex(e1);
    final tw = g.edgeWayIndex(e2);
    var allowed = true;
    for (final r in rs) {
      if (r.fromWay != fw) continue;
      final type = RestrictionType.values[r.type];
      final isOnly = type == RestrictionType.onlyLeftTurn ||
          type == RestrictionType.onlyRightTurn ||
          type == RestrictionType.onlyStraightOn;
      if (isOnly) {
        if (r.toWay != tw) allowed = false;
      } else {
        if (r.toWay == tw) allowed = false;
      }
    }
    return allowed;
  }

  /// Turn cost (equivalent meters) for e1 -> [node] -> e2.
  double turnCostAt(int node, int e1, int e2) {
    if (e1 < 0 || e2 < 0) return 0;
    final p = ctx.profile;
    if (p.turnCostBase <= 0) return 0;
    final s = g.edgeSourceOf(e1);
    final t = g.edgeTarget(e2);
    final b1 = _bearing(g.nodeLatOf(s), g.nodeLonOf(s), g.nodeLatOf(node),
        g.nodeLonOf(node));
    final b2 = _bearing(g.nodeLatOf(node), g.nodeLonOf(node), g.nodeLatOf(t),
        g.nodeLonOf(t));
    var d = b2 - b1;
    while (d > 180) d -= 360;
    while (d <= -180) d += 360;
    var c = turnCost(p, d);
    // Discourage immediate U-turns onto the exact reverse edge strongly,
    // like BRouter's high U-turn penalty (but keep it possible at dead ends).
    if (g.edgeSourceOf(e2) == g.edgeTarget(e1) &&
        t == s &&
        g.edgeWayIndex(e1) == g.edgeWayIndex(e2)) {
      c += p.turnCostBase * 4;
    }
    return c;
  }

  static double _bearing(
      double lat1, double lon1, double lat2, double lon2) {
    final rLat1 = lat1 * math.pi / 180;
    final rLat2 = lat2 * math.pi / 180;
    final dLon = (lon2 - lon1) * math.pi / 180;
    final y = math.sin(dLon) * math.cos(rLat2);
    final x = math.cos(rLat1) * math.sin(rLat2) -
        math.sin(rLat1) * math.cos(rLat2) * math.cos(dLon);
    var brng = math.atan2(y, x) * 180 / math.pi;
    if (brng < 0) brng += 360;
    return brng;
  }

  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dp = (lat2 - lat1) * math.pi / 180;
    final dl = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dp / 2) * math.sin(dp / 2) +
        math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  /// Routes from graph node [start] to graph node [target].
  /// Throws [NoRouteException] if unreachable.
  FoundPath route(int start, int target) {
    if (start == target) return FoundPath(const [], 0);
    final hMin = ctx.minCostPerMeter;
    final tLat = g.nodeLatOf(target), tLon = g.nodeLonOf(target);
    final sLat = g.nodeLatOf(start), sLon = g.nodeLonOf(start);

    double hF(int n) => _haversine(g.nodeLatOf(n), g.nodeLonOf(n), tLat, tLon) * hMin;
    double hB(int n) => _haversine(g.nodeLatOf(n), g.nodeLonOf(n), sLat, sLon) * hMin;

    // Settled states per direction: node -> list of (edge, g).
    final fwdStates = SplayTreeMap<int, List<(int, double)>>();
    final bwdStates = SplayTreeMap<int, List<(int, double)>>();
    final fwdG = <int, double>{};
    final bwdG = <int, double>{};
    final fwdParent = <int, (int, int)>{}; // key -> (prevNode, prevEdge)
    final bwdParent = <int, (int, int)>{}; // key -> (nextNode, nextEdge)

    final fwdHeap = _MinHeap();
    final bwdHeap = _MinHeap();
    fwdHeap.push(_State(start, -1, 0, hF(start)));
    bwdHeap.push(_State(target, -1, 0, hB(target)));

    var bestTotal = double.infinity;
    int? meetNode, meetFwdEdge, meetBwdEdge;
    var fwdGMax = 0.0, bwdGMax = 0.0;

    void tryMeetFwd(int node, int e1, double gf) {
      final bs = bwdStates[node];
      if (bs == null) return;
      for (final (e2, gb) in bs) {
        if (!_turnAllowed(node, e1, e2)) continue;
        final total = gf + gb + turnCostAt(node, e1, e2);
        if (total < bestTotal) {
          bestTotal = total;
          meetNode = node;
          meetFwdEdge = e1;
          meetBwdEdge = e2;
        }
      }
    }

    void tryMeetBwd(int node, int e2, double gb) {
      final fs = fwdStates[node];
      if (fs == null) return;
      for (final (e1, gf) in fs) {
        if (!_turnAllowed(node, e1, e2)) continue;
        final total = gf + gb + turnCostAt(node, e1, e2);
        if (total < bestTotal) {
          bestTotal = total;
          meetNode = node;
          meetFwdEdge = e1;
          meetBwdEdge = e2;
        }
      }
    }

    while (!fwdHeap.isEmpty && !bwdHeap.isEmpty) {
      if (fwdGMax + bwdGMax >= bestTotal) break;
      // Expand the side with the smaller settled progress.
      final forward = fwdGMax <= bwdGMax;
      if (forward) {
        final st = fwdHeap.pop();
        final k = _key(st.node, st.edge);
        if ((fwdG[k] ?? double.infinity) <= st.g) continue;
        fwdG[k] = st.g;
        (fwdStates[st.node] ??= []).add((st.edge, st.g));
        if (st.g > fwdGMax) fwdGMax = st.g;
        tryMeetFwd(st.node, st.edge, st.g);
        for (final e2 in g.edgesOf(st.node)) {
          if (ctx.edgeFactor(e2) == double.infinity) continue;
          if (!_turnAllowed(st.node, st.edge, e2)) continue;
          final ng = st.g +
              ctx.edgeCostMeters(e2) +
              ctx.profile.initialCost +
              turnCostAt(st.node, st.edge, e2);
          final nk = _key(g.edgeTarget(e2), e2);
          if ((fwdG[nk] ?? double.infinity) <= ng) continue;
          fwdParent[nk] = (st.node, st.edge);
          final nn = g.edgeTarget(e2);
          fwdHeap.push(_State(nn, e2, ng, ng + hF(nn)));
        }
      } else {
        final st = bwdHeap.pop();
        final k = _key(st.node, st.edge);
        if ((bwdG[k] ?? double.infinity) <= st.g) continue;
        bwdG[k] = st.g;
        (bwdStates[st.node] ??= []).add((st.edge, st.g));
        if (st.g > bwdGMax) bwdGMax = st.g;
        tryMeetBwd(st.node, st.edge, st.g);
        for (final e1 in g.inEdgesOf(st.node)) {
          if (ctx.edgeFactor(e1) == double.infinity) continue;
          if (!_turnAllowed(st.node, e1, st.edge)) continue;
          final ng = st.g +
              ctx.edgeCostMeters(e1) +
              ctx.profile.initialCost +
              turnCostAt(st.node, e1, st.edge);
          final src = g.edgeSourceOf(e1);
          final nk = _key(src, e1);
          if ((bwdG[nk] ?? double.infinity) <= ng) continue;
          bwdParent[nk] = (st.node, st.edge);
          bwdHeap.push(_State(src, e1, ng, ng + hB(src)));
        }
      }
    }

    if (meetNode == null) {
      throw NoRouteException(
          'no route between graph nodes $start and $target');
    }

    // Reconstruct: forward chain start..meet, then backward chain meet..target.
    final edges = <int>[];
    var node = meetNode!, edge = meetFwdEdge!;
    while (edge >= 0) {
      edges.add(edge);
      final p = fwdParent[_key(node, edge)]!;
      node = p.$1;
      edge = p.$2;
    }
    // Reverse to get start->meet order.
    final fwdEdges = edges.reversed.toList();

    final bwdEdges = <int>[];
    node = meetNode!;
    edge = meetBwdEdge!;
    while (edge >= 0) {
      bwdEdges.add(edge);
      final p = bwdParent[_key(node, edge)]!;
      node = p.$1;
      edge = p.$2;
    }
    fwdEdges.addAll(bwdEdges);
    return FoundPath(fwdEdges, bestTotal);
  }
}
