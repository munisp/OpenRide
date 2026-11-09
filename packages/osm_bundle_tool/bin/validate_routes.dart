/// OpenRide real-world routing validation runner (SPEC §8).
///
/// Loads a bundle's `graph.bin` and runs landmark-to-landmark routes over
/// real OSM data, printing distances, times, wall-clock per route and the
/// top-5 maneuver instructions. Assertions use real-world-plausible road
/// distance bands for Lagos.
///
///   dart run bin/validate_routes.dart [bundleDir]
///
/// (default bundleDir: /mnt/agents/output/lagos-bundle)
///
/// Never crashes on a failed route: [NoRouteException] is caught, reported
/// and counted as a failure.
library validate_routes;

import 'dart:io';

import 'package:nav_engine/nav_engine.dart';

int _pass = 0, _fail = 0;

void _check(String name, bool ok, [String? detail]) {
  if (ok) {
    _pass++;
    stdout.writeln('PASS $name${detail != null ? '  ($detail)' : ''}');
  } else {
    _fail++;
    stdout.writeln('FAIL $name${detail != null ? '  ($detail)' : ''}');
  }
}

String _km(double m) => (m / 1000).toStringAsFixed(2);
String _min(double s) => (s / 60).toStringAsFixed(1);

/// Routes [from] -> [to]; on [NoRouteException] retries with small
/// coordinate nudges (nearest-node snapping can land on a non-routable
/// edge). Returns the winning endpoints actually used.
({RouteResult route, GeoPoint from, GeoPoint to, int nudges})? _tryRoute(
    RouterEngine engine, String label, GeoPoint from, GeoPoint to,
    {Profile profile = Profile.fastbike, int maxNudges = 8}) {
  const step = 0.002;
  for (var i = 0; i <= maxNudges; i++) {
    final f = GeoPoint(from.lat + step * (i % 3), from.lon + step * (i ~/ 3));
    final t = GeoPoint(to.lat + step * (i % 3), to.lon + step * (i ~/ 3));
    try {
      final r = engine.route(RouteRequest(
          from: f, to: t, profile: profile, elevationFromSrtm: false));
      if (i > 0) {
        stdout.writeln('  note: $label needed $i coordinate nudge(s) '
            '(+${(step * (i % 3)).toStringAsFixed(3)} lat, '
            '+${(step * (i ~/ 3)).toStringAsFixed(3)} lon)');
      }
      return (route: r, from: f, to: t, nudges: i);
    } on NoRouteException catch (e) {
      if (i == maxNudges) {
        stdout.writeln('  NoRouteException for $label '
            '(${e.message}); gave up after $maxNudges nudges');
      }
    }
  }
  return null;
}

Future<void> main(List<String> args) async {
  final bundleDir =
      args.isNotEmpty ? args[0] : '/mnt/agents/output/lagos-bundle';
  if (!File('$bundleDir/graph.bin').existsSync()) {
    stderr.writeln('no graph.bin at $bundleDir');
    exitCode = 2;
    return;
  }

  final engine = createRouterEngine();
  final loadSw = Stopwatch()..start();
  await engine.loadGraph(bundleDir);
  loadSw.stop();
  stdout.writeln(
      'graph.bin loaded in ${loadSw.elapsedMilliseconds} ms');

  final rows = <List<String>>[
    ['route', 'profile', 'distance km', 'time min', 'wall ms', 'maneuvers'],
  ];

  void run(String label, GeoPoint from, GeoPoint to, double minKm, double maxKm,
      {Profile profile = Profile.fastbike, bool showManeuvers = false}) {
    final sw = Stopwatch()..start();
    final res =
        _tryRoute(engine, label, from, to, profile: profile);
    sw.stop();
    if (res == null) {
      _check('$label route found', false);
      return;
    }
    final r = res.route;
    final man = buildManeuvers(r);
    _check('$label route found', true,
        '${_km(r.distM)} km, ${_min(r.timeS)} min, ${sw.elapsedMilliseconds} ms wall');
    _check('$label distance plausible (${_km(minKm * 1000)}-'
        '${_km(maxKm * 1000)} km)',
        r.distM >= minKm * 1000 && r.distM <= maxKm * 1000,
        _km(r.distM));
    _check('$label maneuvers non-empty', man.isNotEmpty, '${man.length}');
    rows.add([
      label,
      profile.name,
      _km(r.distM),
      _min(r.timeS),
      '${sw.elapsedMilliseconds}',
      '${man.length}'
    ]);
    if (showManeuvers) {
      stdout.writeln('  top-5 maneuvers ($label):');
      for (final m in man.take(5)) {
        stdout.writeln(
            '    [${(m.distFromStartM / 1000).toStringAsFixed(2)} km] '
            '${m.instruction}'
            '${m.roadName != null ? ' (${m.roadName})' : ''}');
      }
    }
  }

  const unilag = GeoPoint(6.5176, 3.3787);
  const victoriaIsland = GeoPoint(6.4281, 3.4219);
  const ikeja = GeoPoint(6.6018, 3.3515);
  const lekki = GeoPoint(6.4474, 3.4723);

  run('Unilag -> Victoria Island', unilag, victoriaIsland, 8, 25,
      showManeuvers: true);
  run('Ikeja -> Lekki Phase 1', ikeja, lekki, 15, 45);
  run('Unilag -> VI', unilag, victoriaIsland, 8, 25,
      profile: Profile.fastbike);
  run('Unilag -> VI', unilag, victoriaIsland, 8, 25, profile: Profile.carFast);

  stdout.writeln('');
  stdout.writeln('=== validate_routes summary ($bundleDir) ===');
  final widths = List<int>.generate(rows.first.length,
      (c) => rows.map((r) => r[c].length).reduce((a, b) => a > b ? a : b));
  for (final r in rows) {
    stdout.writeln([
      for (var c = 0; c < r.length; c++) r[c].padRight(widths[c]),
    ].join(' | '));
  }
  stdout.writeln('---');
  stdout.writeln('validate_routes: $_pass passed, $_fail failed');
  if (_fail > 0) exitCode = 1;
}
