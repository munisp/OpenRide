// Zero-dependency test harness for packages/router_engine (SPEC §8).
import 'dart:io';
import 'dart:typed_data';

import '../lib/router_engine.dart';
import '../lib/src/router/astar.dart';
import '../lib/src/srtm/srtm.dart';
import 'package:router_engine/testing/pbf_writer.dart';

int _passed = 0;
int _failed = 0;

void t(String name, bool Function() f) {
  try {
    if (f()) {
      _passed++;
      stdout.writeln('PASS $name');
    } else {
      _failed++;
      stdout.writeln('FAIL $name');
    }
  } catch (e, st) {
    _failed++;
    stdout.writeln('FAIL $name: $e\n$st');
  }
}

Future<void> tAsync(String name, Future<bool> Function() f) async {
  try {
    if (await f()) {
      _passed++;
      stdout.writeln('PASS $name');
    } else {
      _failed++;
      stdout.writeln('FAIL $name');
    }
  } catch (e, st) {
    _failed++;
    stdout.writeln('FAIL $name: $e\n$st');
  }
}

void expectEq(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length == b.length) {
      var same = true;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) same = false;
      }
      if (same) return;
    }
    throw StateError('expected $b, got $a');
  }
  if (a != b) throw StateError('expected $b, got $a');
}

void expectClose(double a, double b, double tol) {
  if ((a - b).abs() > tol) throw StateError('expected $b ± $tol, got $a');
}

String tmpDir() => Directory.systemTemp.createTempSync('openride_rt_').path;

Future<void> main() async {
  // =========================================================================
  // PBF round-trip: writer -> reader
  // =========================================================================
  await tAsync('pbf round-trip dense nodes/ways/restriction', () async {
    final dir = tmpDir();
    final path = '$dir/rt.osm.pbf';
    writeOsmPbf(
      path,
      nodes: [
        const PbfNode(10, 48.0, 11.0, {'name': 'A', 'amenity': 'cafe'}),
        const PbfNode(11, 48.001, 11.0),
        const PbfNode(12, 48.001, 11.001, {'barrier': 'bollard'}),
        const PbfNode(13, 48.0, 11.001),
      ],
      ways: [
        const PbfWay(100, [10, 11, 12], {'highway': 'residential', 'name': 'Main St'}),
        const PbfWay(101, [10, 13, 12], {'highway': 'cycleway', 'surface': 'asphalt'}),
      ],
      relations: [
        const PbfRelation(1000, {'type': 'restriction', 'restriction': 'no_left_turn'}, [
          PbfRelationMember(100, 1, 'from'),
          PbfRelationMember(12, 0, 'via'),
          PbfRelationMember(101, 1, 'to'),
        ]),
      ],
    );
    final osm = await readOsmPbf(path);
    expectEq(osm.nodes.length, 4);
    expectEq(osm.ways.length, 2);
    expectEq(osm.restrictions.length, 1);
    final n10 = osm.nodes[10]!;
    expectClose(n10.lat, 48.0, 1e-7);
    expectClose(n10.lon, 11.0, 1e-7);
    expectEq(n10.tags['amenity'], 'cafe');
    final n12 = osm.nodes[12]!;
    expectClose(n12.lat, 48.001, 1e-7);
    expectClose(n12.lon, 11.001, 1e-7);
    expectEq(n12.tags['barrier'], 'bollard');
    expectEq(osm.ways[100]!.nodeRefs, [10, 11, 12]);
    expectEq(osm.ways[100]!.tags['name'], 'Main St');
    expectEq(osm.ways[101]!.tags['surface'], 'asphalt');
    final r = osm.restrictions.first;
    expectEq(r.fromWay, 100);
    expectEq(r.viaNode, 12);
    expectEq(r.toWay, 101);
    expectEq(r.type, RestrictionType.noLeftTurn);
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  await tAsync('pbf delta-coded ids and negative coords', () async {
    final dir = tmpDir();
    final path = '$dir/neg.osm.pbf';
    // Non-monotonic ids + southern/western hemisphere coords.
    writeOsmPbf(
      path,
      nodes: [
        const PbfNode(1000, -33.86, 151.20),
        const PbfNode(500, -33.87, 151.21),
        const PbfNode(2000, -33.88, 151.19),
      ],
      ways: [
        const PbfWay(7, [1000, 500, 2000], {'highway': 'tertiary'}),
      ],
    );
    final osm = await readOsmPbf(path);
    expectEq(osm.nodes.length, 3);
    expectClose(osm.nodes[500]!.lat, -33.87, 1e-7);
    expectClose(osm.nodes[2000]!.lon, 151.19, 1e-7);
    expectEq(osm.ways[7]!.nodeRefs, [1000, 500, 2000]);
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  await tAsync('pbf zlib + framing sanity', () async {
    final dir = tmpDir();
    final path = '$dir/frame.osm.pbf';
    writeOsmPbf(path, nodes: [const PbfNode(1, 0.0, 0.0)], ways: []);
    final bytes = File(path).readAsBytesSync();
    // First 4 bytes = big-endian BlobHeader length, then "OSMHeader" string
    // appears within the header blob bytes.
    final len = ByteData.sublistView(bytes).getUint32(0, Endian.big);
    if (len <= 0 || len > 4096) return false;
    final headerBytes = bytes.sublist(4, 4 + len);
    final asStr = String.fromCharCodes(headerBytes);
    if (!asStr.contains('OSMHeader')) return false;
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // Grid-city routing correctness
  // =========================================================================
  await tAsync('grid-city route correctness (Manhattan distance)', () async {
    final dir = tmpDir();
    const n = 21;
    const step = 0.001;
    final city = GridCity(n, 48.0, 11.0, step);
    final path = '$dir/city.osm.pbf';
    writeOsmPbf(path, nodes: city.nodes, ways: city.ways);
    final graph = await buildGraphFromPbf(path);
    expectEq(graph.nodeCount, n * n);
    expectEq(graph.edgeCount, n * (n - 1) * 2 * 2); // segments x2 dirs, rows+cols
    final engine = createRouterEngine();
    graph.serializeTo('$dir/graph.bin');
    await engine.loadGraph(dir);
    final res = engine.route(RouteRequest(
      from: GeoPoint(city.lat(0, 0), city.lon(0, 0)),
      to: GeoPoint(city.lat(20, 20), city.lon(20, 20)),
      elevationFromSrtm: false,
    ));
    final stepM = const GeoPoint(48.0, 11.0).distanceTo(const GeoPoint(48.0, 11.001));
    final stepNS = const GeoPoint(48.0, 11.0).distanceTo(const GeoPoint(48.001, 11.0));
    final expected = 20 * stepM + 20 * stepNS;
    expectClose(res.distM, expected, expected * 0.02);
    expectEq(res.legs.length, 1);
    if (res.points.length < 41) return false; // Manhattan path has >= 41 nodes
    if (res.timeS <= 0) return false;
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // Oneway respect
  // =========================================================================
  await tAsync('oneway respected (westbound route detours)', () async {
    final dir = tmpDir();
    final city = GridCity(3, 48.0, 11.0, 0.001, wayTagOverrides: {
      2: {'highway': 'residential', 'oneway': 'yes'}, // middle row, eastbound
    });
    final path = '$dir/ow.osm.pbf';
    writeOsmPbf(path, nodes: city.nodes, ways: city.ways);
    final graph = await buildGraphFromPbf(path);
    graph.serializeTo('$dir/graph.bin');
    final engine = createRouterEngine();
    await engine.loadGraph(dir);
    final stepEW = const GeoPoint(48.0, 11.0).distanceTo(const GeoPoint(48.0, 11.001));
    // Eastbound along the oneway row is fine: (1,0) -> (1,2) = 2 segments.
    final fwd = engine.route(RouteRequest(
      from: GeoPoint(city.lat(1, 0), city.lon(1, 0)),
      to: GeoPoint(city.lat(1, 2), city.lon(1, 2)),
      elevationFromSrtm: false,
    ));
    expectClose(fwd.distM, 2 * stepEW, 2 * stepEW * 0.02);
    // Westbound (1,2) -> (1,0) must detour: >= 4 segments worth.
    final bwd = engine.route(RouteRequest(
      from: GeoPoint(city.lat(1, 2), city.lon(1, 2)),
      to: GeoPoint(city.lat(1, 0), city.lon(1, 0)),
      elevationFromSrtm: false,
    ));
    if (bwd.distM < 3.5 * stepEW) return false; // direct 2-seg path must be blocked
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  await tAsync('oneway=-1 reverses direction', () async {
    final dir = tmpDir();
    // single street (0,0)-(0,1) with oneway=-1: allowed only (0,1)->(0,0).
    writeOsmPbf('$dir/m1.osm.pbf', nodes: [
      const PbfNode(1, 48.0, 11.0),
      const PbfNode(2, 48.0, 11.001),
      const PbfNode(3, 48.001, 11.0),
      const PbfNode(4, 48.001, 11.001),
    ], ways: [
      const PbfWay(1, [1, 2], {'highway': 'residential', 'oneway': '-1'}),
      const PbfWay(2, [1, 3], {'highway': 'residential'}),
      const PbfWay(3, [2, 4], {'highway': 'residential'}),
      const PbfWay(4, [3, 4], {'highway': 'residential'}),
    ]);
    final g = await buildGraphFromPbf('$dir/m1.osm.pbf');
    g.serializeTo('$dir/graph.bin');
    final e = createRouterEngine();
    await e.loadGraph(dir);
    final stepEW = const GeoPoint(48.0, 11.0).distanceTo(const GeoPoint(48.0, 11.001));
    final ok = e.route(RouteRequest(
        from: const GeoPoint(48.0, 11.001),
        to: const GeoPoint(48.0, 11.0),
        elevationFromSrtm: false));
    expectClose(ok.distM, stepEW, stepEW * 0.02); // direct reverse allowed
    final detour = e.route(RouteRequest(
        from: const GeoPoint(48.0, 11.0),
        to: const GeoPoint(48.0, 11.001),
        elevationFromSrtm: false));
    if (detour.distM < 2.5 * stepEW) return false;
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // Turn restriction respect
  // =========================================================================
  await tAsync('turn restriction no_left_turn respected', () async {
    final dir = tmpDir();
    // 3x3 grid; center node id 5 at (48.001,11.001).
    final city = GridCity(3, 48.0, 11.0, 0.001);
    // col j=1 way id = 3 + 1 + 1 = 5 (south->north through center),
    // row i=1 way id = 2 (west->east through center).
    final relations = [
      const PbfRelation(9, {'type': 'restriction', 'restriction': 'no_left_turn'}, [
        PbfRelationMember(5, 1, 'from'),
        PbfRelationMember(5, 0, 'via'),
        PbfRelationMember(2, 1, 'to'),
      ]),
    ];
    writeOsmPbf('$dir/tr.osm.pbf',
        nodes: city.nodes, ways: city.ways, relations: relations);
    final g = await buildGraphFromPbf('$dir/tr.osm.pbf');
    if (g.restrictions.isEmpty) return false;
    g.serializeTo('$dir/graph.bin');
    final e = createRouterEngine();
    await e.loadGraph(dir);
    // Route from south-of-center (node 2 at (48.0,11.001)) to west-of-center
    // (node 4 at (48.001,11.0)).
    final res = e.route(RouteRequest(
      from: GeoPoint(city.lat(0, 1), city.lon(0, 1)),
      to: GeoPoint(city.lat(1, 0), city.lon(1, 0)),
      elevationFromSrtm: false,
    ));
    // The forbidden maneuver is ... -> (48.0,11.001) -> (48.001,11.001) ->
    // (48.001,11.0) as consecutive points.
    bool usesForbidden = false;
    for (var i = 0; i + 2 < res.points.length; i++) {
      final a = res.points[i], b = res.points[i + 1], c = res.points[i + 2];
      if ((a.lat - 48.0).abs() < 1e-7 &&
          (a.lon - 11.001).abs() < 1e-7 &&
          (b.lat - 48.001).abs() < 1e-7 &&
          (b.lon - 11.001).abs() < 1e-7 &&
          (c.lat - 48.001).abs() < 1e-7 &&
          (c.lon - 11.0).abs() < 1e-7) {
        usesForbidden = true;
      }
    }
    if (usesForbidden) return false;
    // Sanity: same route with restrictions disabled MAY use the center.
    final profile = CostProfile.trekking()..considerTurnRestrictions = false;
    final ctx = ProfileContext(profile, g, null);
    final astar = BiAStar(g, ctx);
    final na = g.nearestNode(48.0, 11.001);
    final nb = g.nearestNode(48.001, 11.0);
    final free = astar.route(na, nb);
    bool sawCenter = false;
    var node = na;
    final center = g.nearestNode(48.001, 11.001);
    for (final edge in free.edges) {
      node = g.edgeTarget(edge);
      if (node == center) sawCenter = true;
    }
    if (!sawCenter) return false; // unrestricted shortest path goes via center
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // Profile differentiation
  // =========================================================================
  await tAsync('profile differentiation trekking vs fastbike', () async {
    final dir = tmpDir();
    // Direct track A->B (~2.2km) vs secondary-road detour via C,D (~3.3km).
    writeOsmPbf('$dir/pf.osm.pbf', nodes: [
      const PbfNode(1, 48.0, 11.0),
      const PbfNode(2, 48.0, 11.02),
      const PbfNode(3, 48.005, 11.0),
      const PbfNode(4, 48.005, 11.02),
    ], ways: [
      const PbfWay(1, [1, 2], {'highway': 'track'}),
      const PbfWay(2, [1, 3], {'highway': 'secondary'}),
      const PbfWay(3, [3, 4], {'highway': 'secondary'}),
      const PbfWay(4, [4, 2], {'highway': 'secondary'}),
    ]);
    final g = await buildGraphFromPbf('$dir/pf.osm.pbf');
    g.serializeTo('$dir/graph.bin');
    final e = createRouterEngine();
    await e.loadGraph(dir);
    final trek = e.route(RouteRequest(
        from: const GeoPoint(48.0, 11.0),
        to: const GeoPoint(48.0, 11.02),
        profile: Profile.trekking,
        elevationFromSrtm: false));
    final fast = e.route(RouteRequest(
        from: const GeoPoint(48.0, 11.0),
        to: const GeoPoint(48.0, 11.02),
        profile: Profile.fastbike,
        elevationFromSrtm: false));
    // trekking takes the short track; fastbike the longer paved detour.
    if (!(trek.distM < fast.distM * 0.8)) return false;
    if ((trek.distM - fast.distM).abs() < 100) return false; // actually differ
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  await tAsync('car profile forbidden on cycleway-only link', () async {
    final dir = tmpDir();
    writeOsmPbf('$dir/car.osm.pbf', nodes: [
      const PbfNode(1, 48.0, 11.0),
      const PbfNode(2, 48.0, 11.01),
    ], ways: [
      const PbfWay(1, [1, 2], {'highway': 'cycleway'}),
    ]);
    final g = await buildGraphFromPbf('$dir/car.osm.pbf');
    g.serializeTo('$dir/graph.bin');
    final e = createRouterEngine();
    await e.loadGraph(dir);
    // Bicycle can use the cycleway...
    final bike = e.route(RouteRequest(
        from: const GeoPoint(48.0, 11.0),
        to: const GeoPoint(48.0, 11.01),
        profile: Profile.trekking,
        elevationFromSrtm: false));
    if (bike.distM <= 0) return false;
    // ... car cannot.
    var threw = false;
    try {
      e.route(RouteRequest(
          from: const GeoPoint(48.0, 11.0),
          to: const GeoPoint(48.0, 11.01),
          profile: Profile.carFast,
          elevationFromSrtm: false));
    } on NoRouteException {
      threw = true;
    }
    if (!threw) return false;
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // nearestNode
  // =========================================================================
  await tAsync('nearestNode grid index', () async {
    final dir = tmpDir();
    final city = GridCity(10, 48.0, 11.0, 0.001);
    writeOsmPbf('$dir/nn.osm.pbf', nodes: city.nodes, ways: city.ways);
    final g = await buildGraphFromPbf('$dir/nn.osm.pbf');
    // Query near node (5,3) at (48.005, 11.003).
    final idx = g.nearestNode(48.0052, 11.0031);
    expectClose(g.nodeLatOf(idx), 48.005, 1e-7);
    expectClose(g.nodeLonOf(idx), 11.003, 1e-7);
    // Query far outside the grid still returns the boundary-closest node.
    final far = g.nearestNode(49.0, 12.0);
    final cornerLat = g.nodeLatOf(far), cornerLon = g.nodeLonOf(far);
    expectClose(cornerLat, 48.009, 1e-7);
    expectClose(cornerLon, 11.009, 1e-7);
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // Serialize/load round-trip
  // =========================================================================
  await tAsync('serialize/load round-trip', () async {
    final dir = tmpDir();
    final city = GridCity(8, 47.5, 11.5, 0.002);
    writeOsmPbf('$dir/sl.osm.pbf', nodes: city.nodes, ways: city.ways);
    final g1 = await buildGraphFromPbf('$dir/sl.osm.pbf');
    g1.serializeTo('$dir/graph.bin');
    final g2 = RoutingGraph.loadFrom('$dir/graph.bin');
    expectEq(g2.nodeCount, g1.nodeCount);
    expectEq(g2.edgeCount, g1.edgeCount);
    expectEq(g2.wayIds.length, g1.wayIds.length);
    // tags survive
    expectEq(g2.wayTags[0]['highway'], 'residential');
    final e1 = createRouterEngine();
    await e1.loadGraph(dir);
    final r1 = e1.route(RouteRequest(
        from: const GeoPoint(47.5, 11.5),
        to: const GeoPoint(47.514, 11.514),
        elevationFromSrtm: false));
    // route again from re-loaded graph through a fresh engine
    final e2 = createRouterEngine();
    await e2.loadGraph('$dir/graph.bin'); // direct file path
    final r2 = e2.route(RouteRequest(
        from: const GeoPoint(47.5, 11.5),
        to: const GeoPoint(47.514, 11.514),
        elevationFromSrtm: false));
    expectClose(r2.distM, r1.distM, 1.0);
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // SRTM elevation
  // =========================================================================
  await tAsync('srtm bilinear elevation + ascend stats', () async {
    final dir = tmpDir();
    // Way along the meridian lon 11.5, lat 47.1 -> 47.9 (within N47E011).
    final nodes = <PbfNode>[];
    for (var i = 0; i <= 16; i++) {
      nodes.add(PbfNode(1 + i, 47.1 + i * 0.05, 11.5));
    }
    writeOsmPbf('$dir/el.osm.pbf', nodes: nodes, ways: [
      PbfWay(1, [for (var i = 1; i <= 17; i++) i], {'highway': 'tertiary'}),
    ]);
    final g = await buildGraphFromPbf('$dir/el.osm.pbf');
    g.serializeTo('$dir/graph.bin');
    // Synthetic SRTM tile: 1201x1201, elevation = 1000 * fLat (south->north).
    Directory('$dir/srtm').createSync();
    const size = 1201;
    final bd = ByteData(size * size * 2);
    for (var r = 0; r < size; r++) {
      final fLat = 1.0 - r / (size - 1); // row 0 = north edge
      final ele = (1000 * fLat).round();
      for (var c = 0; c < size; c++) {
        bd.setInt16((r * size + c) * 2, ele, Endian.big);
      }
    }
    File('$dir/srtm/N47E011.hgt').writeAsBytesSync(bd.buffer.asUint8List());

    // Direct reader check: midpoint (47.5, 11.5) => ~500m.
    final srtm = SrtmIndex(dir);
    final mid = srtm.elevation(47.5, 11.5);
    if (mid == null) return false;
    expectClose(mid, 500.0, 2.0);
    final quarter = srtm.elevation(47.25, 11.25);
    if (quarter == null) return false;
    expectClose(quarter, 250.0, 2.0);

    final e = createRouterEngine();
    await e.loadGraph(dir);
    final res = e.route(RouteRequest(
      from: const GeoPoint(47.1, 11.5),
      to: const GeoPoint(47.9, 11.5),
      elevationFromSrtm: true,
    ));
    expectClose(res.ascendM, 800.0, 8.0); // 1000 * 0.8
    if (res.descendM > 5.0) return false;
    if (res.points.any((p) => p.ele == null)) return false;
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // Perf smoke: ~50km cross-city
  // =========================================================================
  await tAsync('perf smoke <2s for ~50km route', () async {
    final dir = tmpDir();
    // 101x101 grid, 0.005 deg step -> ~55km x ~37km span.
    final city = GridCity(101, 48.0, 11.0, 0.005);
    writeOsmPbf('$dir/big.osm.pbf', nodes: city.nodes, ways: city.ways);
    final g = await buildGraphFromPbf('$dir/big.osm.pbf');
    g.serializeTo('$dir/graph.bin');
    final e = createRouterEngine();
    await e.loadGraph(dir);
    final sw = Stopwatch()..start();
    final res = e.route(RouteRequest(
      from: GeoPoint(city.lat(0, 0), city.lon(0, 0)),
      to: GeoPoint(city.lat(100, 100), city.lon(100, 100)),
      elevationFromSrtm: false,
    ));
    sw.stop();
    final ms = sw.elapsedMilliseconds;
    stdout.writeln(
        '  perf: ${res.distM.toStringAsFixed(0)} m route in $ms ms '
        '(${g.nodeCount} nodes, ${g.edgeCount} edges)');
    if (res.distM < 80000) return false; // ~100km manhattan at this latitude? no:
    // N-S: 100*0.005deg*111.19km = 55.6km; E-W at 48N: 100*0.005*111.32*cos48
    // = 37.2km -> manhattan ~92.8km.
    if (ms >= 2000) return false;
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // Via points -> legs
  // =========================================================================
  await tAsync('via points split legs', () async {
    final dir = tmpDir();
    final city = GridCity(5, 48.0, 11.0, 0.001);
    writeOsmPbf('$dir/via.osm.pbf', nodes: city.nodes, ways: city.ways);
    final g = await buildGraphFromPbf('$dir/via.osm.pbf');
    g.serializeTo('$dir/graph.bin');
    final e = createRouterEngine();
    await e.loadGraph(dir);
    final res = e.route(RouteRequest(
      from: GeoPoint(city.lat(0, 0), city.lon(0, 0)),
      via: [GeoPoint(city.lat(4, 0), city.lon(4, 0))],
      to: GeoPoint(city.lat(4, 4), city.lon(4, 4)),
      elevationFromSrtm: false,
    ));
    expectEq(res.legs.length, 2);
    // Leg endpoints chain: leg1 ends where leg2 starts (the via node).
    final l1 = res.legs[0], l2 = res.legs[1];
    final end1 = l1.points.last, start2 = l2.points.first;
    expectClose(end1.lat, start2.lat, 1e-9);
    expectClose(end1.lon, start2.lon, 1e-9);
    // Full polyline = leg1 + leg2[1:].
    expectEq(res.points.length, l1.points.length + l2.points.length - 1);
    expectClose(res.distM, l1.distM + l2.distM, 1e-6);
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  // =========================================================================
  // junction=roundabout implies oneway
  // =========================================================================
  await tAsync('junction=roundabout treated as oneway', () async {
    final dir = tmpDir();
    // Ring (1,2,4,3) tagged junction=roundabout + a feeder 0->1 and exit 2->5.
    writeOsmPbf('$dir/ra.osm.pbf', nodes: [
      const PbfNode(0, 48.0, 11.0),
      const PbfNode(1, 48.0, 11.001),
      const PbfNode(2, 48.001, 11.001),
      const PbfNode(3, 48.001, 11.0),
      const PbfNode(4, 48.0005, 11.0015),
      const PbfNode(5, 48.002, 11.001),
    ], ways: [
      const PbfWay(1, [0, 1], {'highway': 'residential'}),
      const PbfWay(2, [1, 2, 3], {
        'highway': 'residential',
        'junction': 'roundabout',
      }),
      const PbfWay(3, [3, 1], {
        'highway': 'residential',
        'junction': 'roundabout',
      }),
      const PbfWay(4, [2, 5], {'highway': 'residential'}),
    ]);
    final g = await buildGraphFromPbf('$dir/ra.osm.pbf');
    g.serializeTo('$dir/graph.bin');
    final e = createRouterEngine();
    await e.loadGraph(dir);
    // Routing 5 -> 0: the roundabout may only be traversed 1->2->3->1, never
    // backwards. Any found route must not traverse ring edges in reverse.
    final res = e.route(RouteRequest(
      from: const GeoPoint(48.002, 11.001),
      to: const GeoPoint(48.0, 11.0),
      elevationFromSrtm: false,
    ));
    // Check no consecutive pair runs counter to 1->2, 2->3, 3->1 direction.
    const pos = {
      1: [48.0, 11.001],
      2: [48.001, 11.001],
      3: [48.001, 11.0],
    };
    bool reverseRing = false;
    for (var i = 0; i + 1 < res.points.length; i++) {
      final a = res.points[i], b = res.points[i + 1];
      for (final entry in pos.entries) {
        if ((a.lat - entry.value[0]).abs() < 1e-7 &&
            (a.lon - entry.value[1]).abs() < 1e-7) {
          for (final e2 in pos.entries) {
            if ((b.lat - e2.value[0]).abs() < 1e-7 &&
                (b.lon - e2.value[1]).abs() < 1e-7) {
              // allowed directed pairs on ring: 1->2, 2->3, 3->1
              final allowed = (entry.key == 1 && e2.key == 2) ||
                  (entry.key == 2 && e2.key == 3) ||
                  (entry.key == 3 && e2.key == 1);
              if (!allowed) reverseRing = true;
            }
          }
        }
      }
    }
    if (reverseRing) return false;
    Directory(dir).deleteSync(recursive: true);
    return true;
  });

  stdout.writeln('---');
  stdout.writeln('router_engine: $_passed passed, $_failed failed');
  if (_failed > 0) exit(1);
}
