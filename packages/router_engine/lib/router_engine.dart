/// OpenRide router engine — BRouter port (SPEC §3.4 public API).
library router_engine;

import 'dart:io';

import 'package:shared/shared.dart';
import 'src/graph/routing_graph.dart';
import 'src/pbf/osm_data.dart';
import 'src/pbf/pbf_reader.dart';
import 'src/profile/cost_profile.dart';
import 'src/router/astar.dart';
import 'src/router/exceptions.dart';
import 'src/srtm/srtm.dart';

export 'package:shared/shared.dart';
export 'src/graph/routing_graph.dart' show RoutingGraph;
export 'src/pbf/osm_data.dart';
export 'src/pbf/pbf_reader.dart' show readOsmPbf, streamOsmPbf, OsmVisitor;
export 'src/profile/cost_profile.dart';
export 'src/router/exceptions.dart';

class RouteRequest {
  final GeoPoint from;
  final GeoPoint to;
  final List<GeoPoint> via;
  final Profile profile;
  final bool elevationFromSrtm;

  RouteRequest({
    required this.from,
    required this.to,
    this.via = const [],
    this.profile = Profile.trekking,
    this.elevationFromSrtm = true,
  });
}

class RouteLeg {
  final List<GeoPoint> points;
  final double distM;
  final double timeS;

  const RouteLeg({required this.points, required this.distM, required this.timeS});
}

class RouteResult {
  final List<GeoPoint> points;
  final double distM;
  final double timeS;
  final double ascendM;
  final double descendM;

  /// Legs split at via points (single leg when no via).
  final List<RouteLeg> legs;

  const RouteResult({
    required this.points,
    required this.distM,
    required this.timeS,
    required this.ascendM,
    required this.descendM,
    required this.legs,
  });
}

abstract class RouterEngine {
  /// Loads graph.bin + elevation tiles (srtm/ dir) if present.
  /// [bundlePath] may be the bundle directory or a direct path to graph.bin.
  Future<void> loadGraph(String bundlePath);

  /// Computes a route; throws [NoRouteException] when impossible.
  RouteResult route(RouteRequest req);
}

RouterEngine createRouterEngine() => _RouterEngineImpl();

class _RouterEngineImpl implements RouterEngine {
  RoutingGraph? _graph;
  SrtmIndex? _srtm;
  String? _bundleDir;

  @override
  Future<void> loadGraph(String bundlePath) async {
    String graphFile;
    String? srtmDir;
    if (FileSystemEntity.isDirectorySync(bundlePath)) {
      graphFile = '$bundlePath/graph.bin';
      srtmDir = '$bundlePath/srtm';
      _bundleDir = bundlePath;
    } else {
      graphFile = bundlePath;
      final slash = bundlePath.lastIndexOf('/');
      final parent = slash >= 0 ? bundlePath.substring(0, slash) : '.';
      srtmDir = '$parent/srtm';
      _bundleDir = parent;
    }
    if (!File(graphFile).existsSync()) {
      throw FileSystemException('graph.bin not found', graphFile);
    }
    _graph = RoutingGraph.loadFrom(graphFile);
    _srtm = Directory(srtmDir).existsSync() ? SrtmIndex(_bundleDir!) : null;
  }

  /// The loaded graph (null before [loadGraph]); exposed for tooling/tests.
  RoutingGraph? get graph => _graph;

  @override
  RouteResult route(RouteRequest req) {
    final g = _graph;
    if (g == null) {
      throw StateError('loadGraph must be called before route()');
    }
    if (g.nodeCount == 0) {
      throw const NoRouteException('graph is empty');
    }

    final profile = CostProfile.forProfile(req.profile);
    double? Function(int node)? elevationOf;
    final srtm = _srtm;
    if (req.elevationFromSrtm && srtm != null) {
      elevationOf = (node) => srtm.elevation(g.nodeLatOf(node), g.nodeLonOf(node));
    }
    final ctx = ProfileContext(profile, g, elevationOf);
    final astar = BiAStar(g, ctx);

    // Waypoints: from, via..., to — one search per leg.
    final waypoints = <GeoPoint>[req.from, ...req.via, req.to];
    final legs = <RouteLeg>[];
    final allPoints = <GeoPoint>[];
    var totalDist = 0.0;
    var totalTime = 0.0;

    for (var legIdx = 0; legIdx + 1 < waypoints.length; legIdx++) {
      final a = waypoints[legIdx];
      final b = waypoints[legIdx + 1];
      final na = g.nearestNode(a.lat, a.lon);
      final nb = g.nearestNode(b.lat, b.lon);
      final path = astar.route(na, nb);

      final pts = <GeoPoint>[GeoPoint(g.nodeLatOf(na), g.nodeLonOf(na))];
      var dist = 0.0, time = 0.0;
      int? prevEdge;
      for (final e in path.edges) {
        final t = g.edgeTarget(e);
        dist += g.edgeDistM(e);
        time += ctx.edgeTimeS(e);
        if (prevEdge != null) {
          final tc = astar.turnCostAt(g.edgeSourceOf(e), prevEdge, e);
          final hw = g.wayTags[g.edgeWayIndex(e)]['highway'] ?? 'road';
          final speed = profile.baseSpeed[hw] ?? 5.0;
          time += tc / speed;
        }
        pts.add(GeoPoint(g.nodeLatOf(t), g.nodeLonOf(t)));
        prevEdge = e;
      }
      legs.add(RouteLeg(points: pts, distM: dist, timeS: time));
      if (allPoints.isNotEmpty && pts.isNotEmpty) {
        allPoints.addAll(pts.skip(1)); // avoid duplicating the via node
      } else {
        allPoints.addAll(pts);
      }
      totalDist += dist;
      totalTime += time;
    }

    // Elevation stats from SRTM (when enabled & available).
    var ascend = 0.0, descend = 0.0;
    if (elevationOf != null) {
      double? prev;
      final withEle = <GeoPoint>[];
      for (final p in allPoints) {
        final e = srtm!.elevation(p.lat, p.lon);
        withEle.add(GeoPoint(p.lat, p.lon, ele: e));
        if (e != null && prev != null) {
          final d = e - prev;
          if (d > 0) {
            ascend += d;
          } else {
            descend -= d;
          }
        }
        if (e != null) prev = e;
      }
      allPoints
        ..clear()
        ..addAll(withEle);
    }

    return RouteResult(
      points: allPoints,
      distM: totalDist,
      timeS: totalTime,
      ascendM: ascend,
      descendM: descend,
      legs: legs,
    );
  }
}

/// Builds a RoutingGraph directly from an .osm.pbf file with the default
/// routable filter (BRouter highway semantics). Convenience for the bundle
/// tool and tests.
Future<RoutingGraph> buildGraphFromPbf(String pbfPath,
    {String accessMode = 'bicycle'}) async {
  final osm = await readOsmPbf(pbfPath);
  return RoutingGraph.build(osm, isRoutable: defaultRoutableFilter);
}

/// Default routable-way filter (SPEC §3.2): highways motorway..path,
/// cycleway, track, ... — profile-specific access is handled at cost time.
bool defaultRoutableFilter(OsmWay way) {
  final highway = way.tags['highway'];
  if (highway == null) return false;
  const routable = {
    'motorway',
    'motorway_link',
    'trunk',
    'trunk_link',
    'primary',
    'primary_link',
    'secondary',
    'secondary_link',
    'tertiary',
    'tertiary_link',
    'unclassified',
    'residential',
    'living_street',
    'service',
    'pedestrian',
    'footway',
    'steps',
    'cycleway',
    'path',
    'track',
    'bridleway',
    'road',
  };
  if (!routable.contains(highway)) return false;
  // area=yes ways (plazas) are not line-routable in this model.
  if (way.tags['area'] == 'yes') return false;
  return true;
}
