import 'dart:io';

import '../lib/nav_engine.dart';
import 'fake_router_engine.dart';

int _passCount = 0;
final List<String> _failures = <String>[];

void t(String name, bool Function() f) {
  try {
    if (f()) {
      _passCount++;
      stdout.writeln('PASS $name');
    } else {
      _failures.add('$name: test returned false');
      stdout.writeln('FAIL $name: test returned false');
    }
  } catch (error, stackTrace) {
    _failures.add('$name: $error');
    stdout.writeln('FAIL $name: $error');
    stderr.writeln(stackTrace);
  }
}

void expectTrue(bool value, [String? message]) {
  if (!value) throw StateError(message ?? 'Expected true');
}

void expectEq(Object? actual, Object? expected, [String? message]) {
  if (actual != expected) {
    throw StateError(
      '${message ?? 'Expected equality'}: expected <$expected>, got <$actual>',
    );
  }
}

void expectClose(
  double actual,
  double expected,
  double tolerance, [
  String? message,
]) {
  if ((actual - expected).abs() > tolerance) {
    throw StateError(
      '${message ?? 'Expected close values'}: expected <$expected>, got <$actual> (±$tolerance)',
    );
  }
}

void expectListEq(
  List<String> actual,
  List<String> expected, [
  String? message,
]) {
  expectEq(
    actual.length,
    expected.length,
    '${message ?? 'List length mismatch'}: $actual',
  );
  for (var i = 0; i < actual.length; i++) {
    expectEq(actual[i], expected[i], '${message ?? 'List mismatch'} at $i');
  }
}

RouteResult routeFromPoints(List<GeoPoint> points) {
  final distM = pathLengthM(points);
  return RouteResult(
    points: points,
    distM: distM,
    timeS: distM / 5.0,
    ascendM: 0,
    descendM: 0,
    legs: <RouteLeg>[
      RouteLeg(points: points, distM: distM, timeS: distM / 5.0),
    ],
  );
}

RouteResult turnRoute(double signedAngleDeg) {
  final start = const GeoPoint(0.0, 0.0);
  final middle = start.destination(0.0, 100.0);
  final end = middle.destination(signedAngleDeg, 100.0);
  return routeFromPoints(<GeoPoint>[start, middle, end]);
}

List<GeoPoint> roundaboutArc(double sweepDeg) {
  final center = const GeoPoint(0.0, 0.0);
  final points = <GeoPoint>[];
  for (var step = 0.0; step <= sweepDeg + 0.001; step += 15.0) {
    final bearing = (180.0 + step) % 360.0;
    points.add(center.destination(bearing, 25.0));
  }
  return points;
}

List<GeoPoint> roundaboutArcWithSpokes(double sweepDeg) {
  final center = const GeoPoint(0.0, 0.0);
  final exitBearing = (180.0 + sweepDeg) % 360.0;
  return <GeoPoint>[
    center.destination(180.0, 85.0),
    ...roundaboutArc(sweepDeg),
    center.destination(exitBearing, 85.0),
  ];
}

String maneuverTypes(Iterable<Maneuver> maneuvers) =>
    maneuvers.map((maneuver) => maneuver.type.name).join(', ');

bool testAngleToTypeMapping() {
  final cases = <MapEntry<double, ManeuverType>>[
    const MapEntry<double, ManeuverType>(-169.5, ManeuverType.sharpLeft),
    const MapEntry<double, ManeuverType>(-120.5, ManeuverType.sharpLeft),
    const MapEntry<double, ManeuverType>(-119.5, ManeuverType.turnLeft),
    const MapEntry<double, ManeuverType>(-45.5, ManeuverType.turnLeft),
    const MapEntry<double, ManeuverType>(-44.5, ManeuverType.slightLeft),
    const MapEntry<double, ManeuverType>(-10.5, ManeuverType.slightLeft),
    const MapEntry<double, ManeuverType>(-9.5, ManeuverType.straight),
    const MapEntry<double, ManeuverType>(0.0, ManeuverType.straight),
    const MapEntry<double, ManeuverType>(9.5, ManeuverType.straight),
    const MapEntry<double, ManeuverType>(10.5, ManeuverType.slightRight),
    const MapEntry<double, ManeuverType>(44.5, ManeuverType.slightRight),
    const MapEntry<double, ManeuverType>(45.5, ManeuverType.turnRight),
    const MapEntry<double, ManeuverType>(119.5, ManeuverType.turnRight),
    const MapEntry<double, ManeuverType>(120.5, ManeuverType.sharpRight),
    const MapEntry<double, ManeuverType>(169.5, ManeuverType.sharpRight),
    const MapEntry<double, ManeuverType>(170.5, ManeuverType.uturn),
  ];

  for (final entry in cases) {
    final maneuvers = buildManeuvers(
      turnRoute(entry.key),
      wayNames: const <String>['Main St', 'Main St', 'Oak Ave'],
    );
    expectEq(maneuvers.length, 3, 'maneuver count for ${entry.key}');
    expectEq(maneuvers[0].type, ManeuverType.depart);
    expectEq(
      maneuvers[1].type,
      entry.value,
      'angle ${entry.key}: ${maneuverTypes(maneuvers)}',
    );
    expectEq(maneuvers[2].type, ManeuverType.arrive);
    expectClose(maneuvers[1].distFromStartM, 100.0, 0.2);
  }

  final rightTurn = buildManeuvers(
    turnRoute(90.0),
    wayNames: const <String>['Main St', 'Main St', 'Oak Ave'],
  );
  expectEq(rightTurn[1].instruction, 'Turn right onto Oak Ave');
  expectEq(rightTurn[1].roadName, 'Oak Ave');
  return true;
}

bool testRoundaboutExitCounting() {
  final cases = <MapEntry<double, int>>[
    const MapEntry<double, int>(90.0, 1),
    const MapEntry<double, int>(180.0, 2),
    const MapEntry<double, int>(270.0, 3),
  ];
  for (final entry in cases) {
    final route = routeFromPoints(roundaboutArc(entry.key));
    final maneuvers = buildManeuvers(route);
    final exits = maneuvers
        .where((maneuver) => maneuver.type == ManeuverType.roundaboutExit)
        .toList();
    expectEq(
      exits.length,
      1,
      'roundabout ${entry.key}: ${maneuverTypes(maneuvers)}',
    );
    expectEq(
      exits.single.exitNumber,
      entry.value,
      'roundabout exit count for ${entry.key}',
    );
    expectTrue(
      maneuvers.any(
        (maneuver) => maneuver.type == ManeuverType.roundaboutEnter,
      ),
      'roundabout enter missing for ${entry.key}',
    );
  }

  final secondExit = buildManeuvers(routeFromPoints(roundaboutArc(180.0)))
      .singleWhere((maneuver) => maneuver.type == ManeuverType.roundaboutExit);
  expectEq(secondExit.instruction, 'In the roundabout, take the 2nd exit');

  final withSpokes = buildManeuvers(
    routeFromPoints(roundaboutArcWithSpokes(180.0)),
  );
  final spokeEnter = withSpokes.singleWhere(
    (maneuver) => maneuver.type == ManeuverType.roundaboutEnter,
  );
  final spokeExit = withSpokes.singleWhere(
    (maneuver) => maneuver.type == ManeuverType.roundaboutExit,
  );
  expectEq(spokeExit.exitNumber, 2);
  expectClose(spokeEnter.distFromStartM, 60.0, 0.5);
  expectTrue(
    spokeExit.distFromStartM > spokeEnter.distFromStartM,
    'roundabout exit must follow enter',
  );
  return true;
}

bool testStreetNameChangeManeuvers() {
  final start = const GeoPoint(0.0, 0.0);
  final straight = routeFromPoints(<GeoPoint>[
    start,
    start.destination(0.0, 100.0),
    start.destination(0.0, 200.0),
    start.destination(0.0, 300.0),
  ]);
  final maneuvers = buildManeuvers(
    straight,
    wayNames: const <String>['Main St', 'Main St', 'Oak Ave', 'Oak Ave'],
  );
  expectEq(maneuvers.length, 3, maneuverTypes(maneuvers));
  expectEq(maneuvers[1].type, ManeuverType.straight);
  expectEq(maneuvers[1].instruction, 'Continue onto Oak Ave');
  expectClose(maneuvers[1].distFromStartM, 100.0, 0.2);

  final p0 = const GeoPoint(0.1, 0.1);
  final p1 = p0.destination(0.0, 100.0);
  final p2 = p1.destination(90.0, 20.0);
  final p3 = p2.destination(90.0, 100.0);
  final merged = buildManeuvers(
    routeFromPoints(<GeoPoint>[p0, p1, p2, p3]),
    wayNames: const <String>['', '', '', 'Oak Ave'],
  );
  expectEq(merged.length, 3, maneuverTypes(merged));
  expectEq(merged[1].type, ManeuverType.turnRight);
  expectEq(merged[1].instruction, 'Turn right onto Oak Ave');
  return true;
}

bool testNavigatorAdvancementAndPromptQueue() {
  final start = const GeoPoint(0.0, 0.0);
  final turn = start.destination(0.0, 300.0);
  final end = turn.destination(90.0, 100.0);
  final route = routeFromPoints(<GeoPoint>[start, turn, end]);
  final engine = FakeRouterEngine();
  var now = DateTime.utc(2025, 1, 1, 12);
  final navigator = Navigator(
    route,
    engine,
    Profile.trekking,
    clock: () => now,
  );

  var state = navigator.update(start, 10.0, 0.0);
  expectEq(state.next?.type, ManeuverType.turnRight);
  expectClose(state.distToNextManeuverM, 300.0, 0.3);
  expectClose(state.remainingM, 400.0, 0.6);
  expectClose(state.etaS, 40.0, 0.1);
  expectListEq(navigator.drainVoicePrompts(), const <String>[]);

  state = navigator.update(start.destination(0.0, 100.0), 10.0, 0.0);
  expectClose(state.distToNextManeuverM, 200.0, 0.3);
  expectListEq(navigator.drainVoicePrompts(), const <String>[
    'In 200 meters, turn right',
  ]);
  expectListEq(navigator.drainVoicePrompts(), const <String>[]);

  state = navigator.update(start.destination(0.0, 250.0), 8.0, 0.0);
  expectClose(state.distToNextManeuverM, 50.0, 0.3);
  expectListEq(navigator.drainVoicePrompts(), const <String>[
    'In 50 meters, turn right',
  ]);

  state = navigator.update(start.destination(0.0, 270.0), 8.0, 0.0);
  expectEq(state.next?.type, ManeuverType.arrive);
  expectClose(state.distToNextManeuverM, 130.0, 0.4);
  expectListEq(navigator.drainVoicePrompts(), const <String>['Turn right']);
  return true;
}

bool testEtaSmoothingAndMinimumSpeed() {
  final start = const GeoPoint(0.2, 0.2);
  final end = start.destination(0.0, 1000.0);
  final route = routeFromPoints(<GeoPoint>[start, end]);
  final engine = FakeRouterEngine();
  final navigator = Navigator(
    route,
    engine,
    Profile.foot,
    clock: () => DateTime.utc(2025),
  );

  var state = navigator.update(start, 10.0, 0.0);
  expectClose(state.remainingM, 1000.0, 0.2);
  expectClose(state.etaS, 100.0, 0.05);

  state = navigator.update(start, 0.0, 0.0);
  expectClose(state.etaS, 1000.0 / 6.5, 0.1);

  final stoppedNavigator = Navigator(
    route,
    engine,
    Profile.foot,
    clock: () => DateTime.utc(2025),
  );
  state = stoppedNavigator.update(start, -2.0, 0.0);
  expectClose(state.etaS, 1000.0, 0.2);
  return true;
}

bool testOffRouteSustainedThenReroute() {
  final start = const GeoPoint(0.4, 0.4);
  final destination = start.destination(90.0, 1000.0);
  final initialRoute = routeFromPoints(<GeoPoint>[start, destination]);
  final offRoutePosition = start.destination(0.0, 50.0);
  final replacementRoute = routeFromPoints(<GeoPoint>[
    offRoutePosition,
    destination,
  ]);
  final engine = FakeRouterEngine()..queuedRoutes.add(replacementRoute);
  var now = DateTime.utc(2025, 1, 1, 12);
  final navigator = Navigator(
    initialRoute,
    engine,
    Profile.trekking,
    clock: () => now,
  );

  var state = navigator.update(start, 10.0, 90.0);
  expectEq(state.rerouting, false);
  expectEq(engine.requests.length, 0);

  state = navigator.update(offRoutePosition, 10.0, 90.0);
  expectTrue(
    state.offRouteDistM > 25.0,
    'cross-track should exceed threshold: ${state.offRouteDistM}',
  );
  expectEq(state.rerouting, false);
  expectEq(engine.requests.length, 0);

  now = now.add(const Duration(seconds: 5));
  state = navigator.update(offRoutePosition, 10.0, 90.0);
  expectEq(state.rerouting, false, 'reroute requires more than 5 seconds');
  expectEq(engine.requests.length, 0);

  now = now.add(const Duration(seconds: 1, milliseconds: 1));
  state = navigator.update(offRoutePosition, 10.0, 90.0);
  expectEq(state.rerouting, true);
  expectEq(engine.requests.length, 1);
  final request = engine.requests.single;
  expectEq(request.from, offRoutePosition);
  expectEq(request.to, destination);
  expectEq(request.profile, Profile.trekking);
  expectEq(request.via.length, 0);
  expectEq(request.elevationFromSrtm, false);
  expectTrue(identical(navigator.currentRoute, replacementRoute));
  expectClose(state.offRouteDistM, 0.0, 0.001);
  expectClose(state.remainingM, replacementRoute.distM, 0.5);

  state = navigator.update(offRoutePosition, 10.0, 90.0);
  expectEq(state.rerouting, false);
  expectEq(engine.requests.length, 1);
  return true;
}

void main() {
  t(
    'angle-to-type mapping is table-driven and complete',
    testAngleToTypeMapping,
  );
  t('roundabout enter/exit pairing counts exits', testRoundaboutExitCounting);
  t(
    'street-name changes create and merge continue maneuvers',
    testStreetNameChangeManeuvers,
  );
  t(
    'navigator advances at 30m and queues 200m/50m prompts',
    testNavigatorAdvancementAndPromptQueue,
  );
  t(
    'ETA uses smoothed speed with minimum-speed clamp',
    testEtaSmoothingAndMinimumSpeed,
  );
  t(
    'sustained off-route position triggers automatic reroute',
    testOffRouteSustainedThenReroute,
  );

  stdout.writeln('PASS count: $_passCount');
  if (_failures.isNotEmpty) {
    stderr.writeln('Failures (${_failures.length}):');
    for (final failure in _failures) {
      stderr.writeln('  $failure');
    }
    exit(1);
  }
}
