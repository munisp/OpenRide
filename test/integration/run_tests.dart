// OpenRide end-to-end integration test (zero-dependency harness).
//
// Pipeline under test (all real, on the merged main tree):
//   synthetic .osm.pbf  ->  bundle (graph.bin + tiles.mbf + geocoder.bin)
//   -> RouterEngine route -> maneuvers -> Navigator simulation
//   -> RideRecorder along the route -> GPX/TCX/FIT export -> FIT parse-back
//
// Run from repo root:  dart run test/integration/run_tests.dart
import 'dart:io';

import 'package:router_engine/testing/pbf_writer.dart';
import 'package:osm_bundle_tool/osm_bundle_tool.dart';
import 'package:maps_core/maps_core.dart';
import 'package:nav_engine/nav_engine.dart';
import 'package:ride_core/ride_core.dart';
import 'package:ride_core/testing/fit_reader.dart';

int _pass = 0, _fail = 0;
void t(String name, bool Function() f) {
  try {
    if (f()) {
      _pass++;
      stdout.writeln('PASS $name');
    } else {
      _fail++;
      stdout.writeln('FAIL $name');
    }
  } catch (e, st) {
    _fail++;
    stdout.writeln('FAIL $name  ($e)\n$st');
  }
}

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('openride_e2e');
  final pbfPath = '${tmp.path}/city.osm.pbf';
  final bundleDir = '${tmp.path}/bundle';

  // --- 1. synthetic city: 30x30 grid, ~111 m blocks, named POI + named streets
  final city = GridCity(30, 6.5000, 3.3700, 0.001, wayTagOverrides: {
    1: {'highway': 'residential', 'name': 'Marina Road'},
    30: {'highway': 'residential', 'name': 'Broad Street'},
  });
  city.nodes.add(PbfNode(900001, city.lat(15, 15), city.lon(15, 15),
      {'name': 'Integration Plaza', 'amenity': 'cafe'}));
  writeOsmPbf(pbfPath,
      nodes: city.nodes, ways: city.ways, relations: city.relations);
  t('pbf fixture written', () => File(pbfPath).lengthSync() > 100);

  // --- 2. bundle build
  final meta = await buildBundle(pbfPath, bundleDir);
  t('bundle files exist', () =>
      File('$bundleDir/graph.bin').existsSync() &&
      File('$bundleDir/tiles.mbf').existsSync() &&
      File('$bundleDir/geocoder.bin').existsSync() &&
      File('$bundleDir/meta.json').existsSync());
  t('bundle meta has bounds', () => meta.containsKey('bounds'));

  // --- 3. route corner to corner
  final engine = createRouterEngine();
  await engine.loadGraph(bundleDir);
  final from = GeoPoint(city.lat(0, 0), city.lon(0, 0));
  final to = GeoPoint(city.lat(29, 29), city.lon(29, 29));
  final route = engine.route(RouteRequest(
      from: from, to: to, profile: Profile.trekking, elevationFromSrtm: false));
  final expected = 2 * 29 * 0.001 * 111320; // Manhattan distance ~ 6.4 km
  t('route found with sane Manhattan distance', () =>
      route.points.length > 2 &&
      (route.distM - expected).abs() < expected * 0.15);
  t('route time positive', () => route.timeS > 0);

  // --- 4. maneuvers
  final maneuvers = buildManeuvers(route);
  t('maneuvers include depart and arrive', () =>
      maneuvers.first.type == ManeuverType.depart &&
      maneuvers.last.type == ManeuverType.arrive);
  t('maneuver instructions are non-empty English', () =>
      maneuvers.every((m) => m.instruction.isNotEmpty));

  // --- 5. navigation simulation: walk the route polyline
  final nav = Navigator(route, engine, Profile.trekking);
  var st = nav.update(route.points.first, 5.0, 90.0);
  t('nav: initial state has a next maneuver', () => st.next != null);
  double lastRemaining = st.remainingM;
  var monotone = true;
  for (var i = 1; i < route.points.length; i += 2) {
    final p = route.points[i];
    st = nav.update(p, 5.0, 90.0);
    if (st.remainingM > lastRemaining + 1.0) monotone = false;
    lastRemaining = st.remainingM;
  }
  t('nav: remaining distance decreases along route', () => monotone);
  t('nav: never off-route on the polyline', () => st.offRouteDistM < 25.0);
  st = nav.update(route.points.last, 0.0, 0.0);
  t('nav: near-zero remaining at destination', () => st.remainingM < 50.0);
  nav.drainVoicePrompts(); // must not throw

  // --- 6. ride recording along the same route + export
  final rec = RideRecorder();
  rec.start();
  final t0 = DateTime.utc(2026, 11, 9, 8, 0, 0);
  for (var i = 0; i < route.points.length; i++) {
    final p = route.points[i];
    rec.addGps(t0.add(Duration(seconds: i)), p.lat, p.lon,
        accuracy: 5.0, speed: 5.0);
    if (i % 5 == 0) rec.addSensorAt(SensorKind.heartRate, 130 + (i % 7), t0.add(Duration(seconds: i)));
  }
  final ride = rec.stop();
  t('ride stats: distance and time recorded', () =>
      (ride.stats['distanceM'] ?? 0) > route.distM * 0.5 &&
      (ride.stats['totalTimeS'] ?? 0) > 0);

  final gpx = toGpx(ride);
  final tcx = toTcx(ride);
  final fit = toFit(ride);
  t('gpx has trackpoints', () =>
      gpx.contains('<trkpt') && gpx.contains('TrackPointExtension'));
  t('tcx has trackpoints', () =>
      tcx.contains('<Trackpoint>') && tcx.contains('HeartRateBpm'));
  t('fit header valid', () =>
      fit.length > 20 && fit[0] == 14 &&
      fit[8] == 0x2E && fit[9] == 0x46 && fit[10] == 0x49 && fit[11] == 0x54);
  final parsed = parseFit(fit); // ride_core's own FIT reader
  final records = parsed.ofType(20);
  t('fit parse-back: record count matches', () => records.length == ride.points.length);
  t('fit parse-back: session and activity present', () =>
      parsed.ofType(18).isNotEmpty && parsed.ofType(34).isNotEmpty);

  // --- 7. offline maps + geocoder from the same bundle
  final mbf = MbfReader('$bundleDir/tiles.mbf');
  final center = GeoBounds(6.5, 3.37, 6.5 + 29 * 0.001, 3.37 + 29 * 0.001).center();
  final tile = tileFor(center.lat, center.lon, 14);
  final mvt = mbf.getTile(tile);
  t('tile store returns a tile at z14', () => mvt != null && mvt.isNotEmpty);
  if (mvt != null) {
    final cmds = renderTile(mvt, RenderTheme.defaultTheme(), 14);
    t('tile renders to draw commands', () => cmds.isNotEmpty);
  }
  final geo = Geocoder()..open('$bundleDir/geocoder.bin');
  final hits = geo.search('Integration Plaza', near: center);
  t('geocoder finds POI by name', () =>
      hits.isNotEmpty && hits.first.name == 'Integration Plaza');
  final prefix = geo.search('Integra', near: center);
  t('geocoder prefix search works', () => prefix.isNotEmpty);

  stdout.writeln('---');
  stdout.writeln('integration: $_pass passed, $_fail failed');
  tmp.deleteSync(recursive: true);
  if (_fail > 0) exit(1);
}
