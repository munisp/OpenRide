// Unit coverage for bbox extraction (SPEC §3.5 / §8): synthetic PBF via the
// router_engine fixture writer; bbox keeps interior ways+nodes, drops
// exterior ones, keeps clipped ways whole, keeps named in-bbox POIs, and
// filters turn restrictions by surviving ways.
// Spawned as a subprocess by run_tests.dart.
import 'dart:io';

import 'package:router_engine/router_engine.dart';
import 'package:router_engine/testing/pbf_writer.dart';
import '../bin/build_bundle_bbox.dart';
import '../lib/src/bundle_build.dart';

void _expect(bool cond, String what) {
  if (!cond) {
    stderr.writeln('assertion failed: $what');
    exit(1);
  }
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('openride_bbox_').path;
  final pbf = '$dir/in.osm.pbf';
  final out = '$dir/bundle';

  // 6x6 grid: lat 6.40..6.45, lon 3.10..3.15 (step 0.01).
  // Horizontal ways 1..6 (one per row), vertical ways 7..12 (one per col).
  final city = GridCity(6, 6.40, 3.10, 0.01);
  final nodes = <PbfNode>[
    ...city.nodes,
    // named POIs: one inside the bbox, one outside
    const PbfNode(9001, 6.41, 3.11, {'name': 'Inside Cafe', 'amenity': 'cafe'}),
    const PbfNode(9002, 6.50, 3.20, {'name': 'Outside Bar', 'amenity': 'bar'}),
    // untagged standalone node inside the bbox: must be dropped
    const PbfNode(9003, 6.415, 3.115),
  ];
  final relations = <PbfRelation>[
    // from way 1 (kept) via node 1 to way 7 (kept) -> survives
    const PbfRelation(100, {'type': 'restriction', 'restriction': 'no_left_turn'}, [
      PbfRelationMember(1, 1, 'from'),
      PbfRelationMember(1, 0, 'via'),
      PbfRelationMember(7, 1, 'to'),
    ]),
    // from way 4 (exterior) via node 22 to way 10 (exterior) -> dropped
    const PbfRelation(101, {'type': 'restriction', 'restriction': 'no_right_turn'}, [
      PbfRelationMember(4, 1, 'from'),
      PbfRelationMember(22, 0, 'via'),
      PbfRelationMember(10, 1, 'to'),
    ]),
  ];
  writeOsmPbf(pbf, nodes: nodes, ways: city.ways, relations: relations);

  try {
    // Bbox covers rows 0..2 and cols 0..2 (lat <= 6.425, lon <= 3.125).
    const bbox = BBox(6.40, 3.10, 6.425, 3.125);
    final data = await extractBbox(pbf, bbox);

    // Interior ways kept: horizontal 1..3 (rows 0..2), vertical 7..9 (cols 0..2).
    for (final id in [1, 2, 3, 7, 8, 9]) {
      _expect(data.ways.containsKey(id), 'interior way $id kept');
    }
    // Exterior ways dropped.
    for (final id in [4, 5, 6, 10, 11, 12]) {
      _expect(!data.ways.containsKey(id), 'exterior way $id dropped');
    }
    _expect(data.wayCount == 6, 'exactly 6 ways kept, got ${data.wayCount}');

    // Clipped ways stay whole: way 1 (row 0) spans lon 3.10..3.15, so all
    // its nodes (ids 1..6) must be present even beyond lon 3.125.
    for (var id = 1; id <= 6; id++) {
      _expect(data.nodes.containsKey(id), 'way 1 node $id materialized');
    }
    _expect(data.nodes[6]!.lon > 3.13, 'node 6 is outside the bbox');
    // Way 7 (col 0) spans lat 6.40..6.45: top node (id 31) materialized.
    _expect(data.nodes.containsKey(city.nodeId(5, 0)),
        'way 7 top node materialized');

    // Nodes referenced only by dropped ways are gone (e.g. nodeId(5,5)).
    _expect(!data.nodes.containsKey(city.nodeId(5, 5)),
        'exterior-only node dropped');

    // Named POI inside bbox kept, outside dropped, untagged standalone dropped.
    _expect(data.nodes.containsKey(9001), 'in-bbox named POI kept');
    _expect(!data.nodes.containsKey(9002), 'out-of-bbox named POI dropped');
    _expect(!data.nodes.containsKey(9003), 'untagged standalone node dropped');

    // Turn restrictions filtered by surviving ways.
    _expect(data.restrictions.length == 1,
        'one restriction kept, got ${data.restrictions.length}');
    _expect(data.restrictions.single.fromWay == 1,
        'kept restriction is the interior one');

    // The extracted data drives the standard bundle build.
    await buildBundleFromData(data, out, sourceBytes: File(pbf).lengthSync());
    for (final f in ['graph.bin', 'geocoder.bin', 'tiles.mbf', 'meta.json']) {
      _expect(File('$out/$f').existsSync(), 'bundle file $f exists');
    }
    final engine = createRouterEngine();
    await engine.loadGraph(out);
    final res = engine.route(RouteRequest(
      from: const GeoPoint(6.40, 3.10),
      to: const GeoPoint(6.42, 3.12),
      elevationFromSrtm: false,
    ));
    _expect(res.distM > 0 && res.points.length >= 2,
        'routing works on the extracted bundle');
  } catch (e, st) {
    stderr.writeln('bbox_extract test failed: $e\n$st');
    exit(1);
  } finally {
    Directory(dir).deleteSync(recursive: true);
  }
  stdout.writeln('bbox_extract test OK');
}
