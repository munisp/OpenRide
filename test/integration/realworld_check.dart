// OpenRide REAL-WORLD validation (SPEC §8): routes, geocoder and tiles
// against a bundle built from real OpenStreetMap data (Lagos, Nigeria).
//
// Guarded: skips cleanly (exit 0) when the bundle is absent, so the default
// test run is never broken. Build the bundle first, e.g.:
//
//   dart run packages/osm_bundle_tool/bin/build_bundle_bbox.dart \
//     nigeria.osm.pbf /tmp/lagos-bundle 6.39 3.10 6.72 3.62
//
// then:
//
//   dart run test/integration/realworld_check.dart
//   BUNDLE_DIR=/path/to/bundle dart run test/integration/realworld_check.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:maps_core/maps_core.dart';
import 'package:nav_engine/nav_engine.dart';

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
  } catch (e) {
    _fail++;
    stdout.writeln('FAIL $name  ($e)');
  }
}

String _km(double m) => (m / 1000).toStringAsFixed(2);
String _min(double s) => (s / 60).toStringAsFixed(1);

void _row(List<List<String>> rows, String route, RouteResult r, int nMan) {
  rows.add([route, _km(r.distM), _min(r.timeS), '$nMan']);
}

Future<void> main() async {
  final bundleDir = Platform.environment['BUNDLE_DIR'] ?? '/tmp/lagos-bundle';
  if (!File('$bundleDir/graph.bin').existsSync() ||
      !File('$bundleDir/tiles.mbf').existsSync() ||
      !File('$bundleDir/geocoder.bin').existsSync()) {
    stdout.writeln('SKIP realworld_check: no bundle at $bundleDir '
        '(set BUNDLE_DIR or build /tmp/lagos-bundle first)');
    return;
  }
  stdout.writeln('realworld_check: using bundle at $bundleDir');

  final engine = createRouterEngine();
  await engine.loadGraph(bundleDir);
  final rows = <List<String>>[
    ['route', 'distance km', 'time min', 'maneuvers'],
  ];

  // --- 1. Unilag -> Victoria Island -----------------------------------------
  const unilag = GeoPoint(6.5176, 3.3787);
  const victoriaIsland = GeoPoint(6.4281, 3.4219);
  RouteResult? r1;
  List<Maneuver> m1 = const [];
  t('route Unilag -> Victoria Island found', () {
    r1 = engine.route(RouteRequest(
        from: unilag, to: victoriaIsland, elevationFromSrtm: false));
    m1 = buildManeuvers(r1!);
    return true;
  });
  if (r1 != null) {
    final d = r1!.distM;
    t('Unilag -> VI distance plausible (8-25 km by road)',
        () => d >= 8000 && d <= 25000);
    t('Unilag -> VI maneuvers non-empty', () => m1.isNotEmpty);
    _row(rows, 'Unilag -> Victoria Island', r1!, m1.length);
    stdout.writeln('  top-5 maneuvers (Unilag -> VI):');
    for (final m in m1.take(5)) {
      stdout.writeln('    [${(m.distFromStartM / 1000).toStringAsFixed(2)} km] '
          '${m.instruction}${m.roadName != null ? ' (${m.roadName})' : ''}');
    }
  }

  // --- 2. Ikeja -> Lekki Phase 1 ---------------------------------------------
  const ikeja = GeoPoint(6.6018, 3.3515);
  const lekki = GeoPoint(6.4474, 3.4723);
  RouteResult? r2;
  t('route Ikeja -> Lekki Phase 1 found', () {
    r2 = engine.route(RouteRequest(
        from: ikeja, to: lekki, elevationFromSrtm: false));
    return true;
  });
  if (r2 != null) {
    final d = r2!.distM;
    t('Ikeja -> Lekki distance plausible (15-45 km)',
        () => d >= 15000 && d <= 45000);
    _row(rows, 'Ikeja -> Lekki Phase 1', r2!, buildManeuvers(r2!).length);
  }

  // --- 3. profile comparison on Unilag -> VI ---------------------------------
  RouteResult? rb, rc;
  t('Profile.fastbike succeeds', () {
    rb = engine.route(RouteRequest(
        from: unilag,
        to: victoriaIsland,
        profile: Profile.fastbike,
        elevationFromSrtm: false));
    return rb!.distM > 0;
  });
  t('Profile.carFast succeeds', () {
    rc = engine.route(RouteRequest(
        from: unilag,
        to: victoriaIsland,
        profile: Profile.carFast,
        elevationFromSrtm: false));
    return rc!.distM > 0;
  });
  if (rb != null) {
    _row(rows, 'Unilag -> VI (fastbike)', rb!, buildManeuvers(rb!).length);
  }
  if (rc != null) {
    _row(rows, 'Unilag -> VI (carFast)', rc!, buildManeuvers(rc!).length);
  }

  // --- 4. geocoder -------------------------------------------------------------
  final geo = Geocoder()..open('$bundleDir/geocoder.bin');
  var anyHits = false;
  for (final q in ['University of Lagos', 'Eko Hotel', 'Lekki']) {
    final hits = geo.search(q, near: const GeoPoint(6.45, 3.40));
    t('geocoder finds "$q"', () => hits.isNotEmpty);
    if (hits.isNotEmpty) anyHits = true;
    stdout.writeln('  geocoder "$q" top hits:');
    for (final h in hits.take(3)) {
      stdout.writeln('    ${h.name} [${h.kind}] @ '
          '${h.point.lat.toStringAsFixed(4)},${h.point.lon.toStringAsFixed(4)}');
    }
  }
  t('geocoder returns results for >=1 well-known Lagos name', () => anyHits);

  // --- 5. vector tiles -----------------------------------------------------------
  final mbf = MbfReader('$bundleDir/tiles.mbf');
  final zooms = mbf.zooms();
  t('tiles.mbf has zoom levels', () => zooms.isNotEmpty);
  Uint8List? tile;
  t('z14 tile at Victoria Island present', () {
    if (!zooms.contains(14)) return false;
    tile = mbf.getTile(tileFor(6.4281, 3.4219, 14));
    return tile != null && tile!.isNotEmpty;
  });
  if (tile != null) {
    t('z14 VI tile renders to non-empty DrawCommands', () {
      final cmds = renderTile(tile!, RenderTheme.defaultTheme(), 14);
      stdout.writeln('  z14 VI tile: ${tile!.length} bytes, '
          '${cmds.length} draw commands');
      return cmds.isNotEmpty;
    });
  }
  mbf.close();

  // --- 6. summary ------------------------------------------------------------------
  stdout.writeln('');
  stdout.writeln('=== realworld_check summary ===');
  final widths = List<int>.generate(rows.first.length,
      (c) => rows.map((r) => r[c].length).reduce((a, b) => a > b ? a : b));
  for (final r in rows) {
    stdout.writeln([
      for (var c = 0; c < r.length; c++) r[c].padRight(widths[c]),
    ].join(' | '));
  }
  stdout.writeln('---');
  stdout.writeln('realworld_check: $_pass passed, $_fail failed');
  if (_fail > 0) exit(1);
}
