// End-to-end bundle tool test (SPEC §8): tiny extract -> bundle -> load.
// Only compiled/run when maps_core writer sources are present (see
// run_tests.dart, which spawns this file as a subprocess).
import 'dart:convert';
import 'dart:io';

import 'package:maps_core/maps_core.dart';
import 'package:router_engine/router_engine.dart';
import 'package:router_engine/testing/pbf_writer.dart';
import '../bin/build_bundle.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('openride_bt_').path;
  final pbf = '$dir/in.osm.pbf';
  final out = '$dir/bundle';

  final city = GridCity(6, 48.1, 11.6, 0.001, wayTagOverrides: {
    1: {'highway': 'residential', 'name': 'Hauptstrasse'},
  });
  writeOsmPbf(
    pbf,
    nodes: [
      ...city.nodes,
      const PbfNode(
          9001, 48.101, 11.601, {'name': 'Test Cafe', 'amenity': 'cafe'}),
    ],
    ways: city.ways,
  );

  try {
    await buildBundle(pbf, out);

    // Files exist.
    for (final f in ['graph.bin', 'geocoder.bin', 'tiles.mbf', 'meta.json']) {
      if (!File('$out/$f').existsSync()) {
        stderr.writeln('missing bundle file $f');
        exit(1);
      }
    }

    // meta.json sane.
    final meta = jsonDecode(File('$out/meta.json').readAsStringSync());
    final bounds = meta['bounds'];
    if ((bounds['maxLat'] as num) <= (bounds['minLat'] as num)) exit(1);
    if ((meta['sourceBytes'] as num) <= 0) exit(1);
    if (meta['generatedAt'] is! String) exit(1);

    // graph.bin loads & routes.
    final engine = createRouterEngine();
    await engine.loadGraph(out);
    final res = engine.route(RouteRequest(
      from: const GeoPoint(48.1, 11.6),
      to: const GeoPoint(48.105, 11.605),
      elevationFromSrtm: false,
    ));
    if (res.distM <= 0 || res.points.length < 2) exit(1);

    // tiles.mbf loads & random-reads.
    final reader = MbfReader('$out/tiles.mbf');
    final zooms = reader.zooms();
    if (zooms.isEmpty) exit(1);
    final b = reader.bounds();
    if (b.maxLat <= b.minLat) exit(1);
    final id = tileFor(48.1025, 11.6025, zooms.last);
    final tile = reader.getTile(id);
    reader.close();
    if (tile == null || tile.isEmpty) exit(1);

    // geocoder.bin opens & finds the cafe by prefix.
    final geo = Geocoder()..open('$out/geocoder.bin');
    final hits = geo.search('Test Caf');
    if (hits.isEmpty || !hits.first.name.contains('Test Cafe')) exit(1);
  } catch (e, st) {
    stderr.writeln('e2e failed: $e\n$st');
    exit(1);
  } finally {
    Directory(dir).deleteSync(recursive: true);
  }
  stdout.writeln('e2e bundle test OK');
}
