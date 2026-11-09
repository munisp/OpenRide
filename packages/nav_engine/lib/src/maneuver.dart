import 'dart:math' as math;

import 'api.dart';

class Maneuver {
  final ManeuverType type;
  final double lat;
  final double lon;
  final double distFromStartM;
  final String instruction;
  final String? roadName;
  final int? exitNumber;

  const Maneuver({
    required this.type,
    required this.lat,
    required this.lon,
    required this.distFromStartM,
    required this.instruction,
    this.roadName,
    this.exitNumber,
  });

  @override
  String toString() =>
      'Maneuver(type: $type, lat: $lat, lon: $lon, distFromStartM: '
      '$distFromStartM, instruction: $instruction, roadName: $roadName, '
      'exitNumber: $exitNumber)';
}

enum ManeuverType {
  depart,
  turnLeft,
  turnRight,
  slightLeft,
  slightRight,
  sharpLeft,
  sharpRight,
  uturn,
  straight,
  roundaboutEnter,
  roundaboutExit,
  arrive,
}

List<Maneuver> buildManeuvers(RouteResult route, {List<String>? wayNames}) {
  final points = route.points;
  if (points.isEmpty) return const <Maneuver>[];

  final cumulative = cumulativeDistancesM(points);
  final firstName = _nameAfter(0, points.length, wayNames);
  final maneuvers = <Maneuver>[
    Maneuver(
      type: ManeuverType.depart,
      lat: points.first.lat,
      lon: points.first.lon,
      distFromStartM: 0.0,
      instruction: _instructionFor(ManeuverType.depart, firstName),
      roadName: firstName,
    ),
  ];

  if (points.length == 1) {
    maneuvers.add(
      Maneuver(
        type: ManeuverType.arrive,
        lat: points.first.lat,
        lon: points.first.lon,
        distFromStartM: 0.0,
        instruction: _instructionFor(ManeuverType.arrive, null),
      ),
    );
    return maneuvers;
  }

  final roundabouts = _detectRoundabouts(points, cumulative);
  for (final roundabout in roundabouts) {
    if (roundabout.entryIndex == 0) {
      maneuvers.add(
        _roundaboutManeuver(
          ManeuverType.roundaboutEnter,
          points,
          cumulative,
          roundabout.entryIndex,
          _nameBefore(roundabout.entryIndex, points.length, wayNames),
        ),
      );
    }
  }

  for (var i = 1; i < points.length - 1; i++) {
    final roundaboutEvent = _roundaboutEventAt(i, roundabouts);
    if (roundaboutEvent != null) {
      maneuvers.add(
        _roundaboutManeuver(
          roundaboutEvent.type,
          points,
          cumulative,
          i,
          roundaboutEvent.type == ManeuverType.roundaboutExit
              ? _nameAfter(i, points.length, wayNames)
              : _nameBefore(i, points.length, wayNames),
          exitNumber: roundaboutEvent.exitNumber,
        ),
      );
      continue;
    }
    if (_isInsideRoundabout(i, roundabouts)) continue;

    final angle = signedTurnAngle(points[i - 1], points[i], points[i + 1]);
    final type = _typeForAngle(angle);
    final incomingName = _nameBefore(i, points.length, wayNames);
    final outgoingName = _nameAfter(i, points.length, wayNames);
    final nameChanged =
        incomingName != outgoingName &&
        (incomingName != null || outgoingName != null);

    if (type == ManeuverType.straight && !nameChanged) continue;

    final roadName = outgoingName ?? incomingName;
    maneuvers.add(
      Maneuver(
        type: type,
        lat: points[i].lat,
        lon: points[i].lon,
        distFromStartM: cumulative[i],
        instruction: type == ManeuverType.straight
            ? _instructionFor(type, outgoingName)
            : _instructionFor(type, roadName),
        roadName: roadName,
      ),
    );
  }

  for (final roundabout in roundabouts) {
    if (roundabout.exitIndex == points.length - 1) {
      maneuvers.add(
        _roundaboutManeuver(
          ManeuverType.roundaboutExit,
          points,
          cumulative,
          roundabout.exitIndex,
          _nameAfter(roundabout.exitIndex, points.length, wayNames),
          exitNumber: roundabout.exitNumber,
        ),
      );
    }
  }

  maneuvers.add(
    Maneuver(
      type: ManeuverType.arrive,
      lat: points.last.lat,
      lon: points.last.lon,
      distFromStartM: cumulative.last,
      instruction: _instructionFor(ManeuverType.arrive, null),
    ),
  );

  return _mergeNameChangeManeuvers(maneuvers);
}

ManeuverType _typeForAngle(double angleDeg) {
  const epsilon = 0.000001;
  final absolute = angleDeg.abs();
  if (absolute >= 170.0 - epsilon) return ManeuverType.uturn;
  if (absolute >= 120.0 - epsilon && absolute > 120.0 + epsilon) {
    return angleDeg > 0 ? ManeuverType.sharpRight : ManeuverType.sharpLeft;
  }
  if (absolute >= 120.0 - epsilon) {
    return angleDeg > 0 ? ManeuverType.turnRight : ManeuverType.turnLeft;
  }
  if (absolute >= 45.0 - epsilon) {
    return angleDeg > 0 ? ManeuverType.turnRight : ManeuverType.turnLeft;
  }
  if (absolute >= 10.0 - epsilon) {
    return angleDeg > 0 ? ManeuverType.slightRight : ManeuverType.slightLeft;
  }
  return ManeuverType.straight;
}

String _instructionFor(ManeuverType type, String? roadName, {int? exitNumber}) {
  final suffix = roadName == null ? '' : ' onto $roadName';
  switch (type) {
    case ManeuverType.depart:
      return 'Depart$suffix';
    case ManeuverType.turnLeft:
      return 'Turn left$suffix';
    case ManeuverType.turnRight:
      return 'Turn right$suffix';
    case ManeuverType.slightLeft:
      return 'Turn slight left$suffix';
    case ManeuverType.slightRight:
      return 'Turn slight right$suffix';
    case ManeuverType.sharpLeft:
      return 'Make a sharp left$suffix';
    case ManeuverType.sharpRight:
      return 'Make a sharp right$suffix';
    case ManeuverType.uturn:
      return 'Make a U-turn$suffix';
    case ManeuverType.straight:
      return roadName == null ? 'Continue straight' : 'Continue onto $roadName';
    case ManeuverType.roundaboutEnter:
      return 'Enter the roundabout';
    case ManeuverType.roundaboutExit:
      return 'In the roundabout, take the ${_ordinal(exitNumber ?? 1)} exit$suffix';
    case ManeuverType.arrive:
      return 'Arrive at destination';
  }
}

String _ordinal(int value) {
  final teenRemainder = value % 100;
  if (teenRemainder >= 11 && teenRemainder <= 13) return '${value}th';
  switch (value % 10) {
    case 1:
      return '${value}st';
    case 2:
      return '${value}nd';
    case 3:
      return '${value}rd';
    default:
      return '${value}th';
  }
}

String? _cleanName(String? name) {
  final trimmed = name?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String? _nameBefore(int vertexIndex, int pointCount, List<String>? wayNames) {
  if (wayNames == null || wayNames.isEmpty || pointCount < 2) return null;
  if (wayNames.length == pointCount) {
    return _cleanName(wayNames[vertexIndex.clamp(0, pointCount - 1)]);
  }
  final segmentIndex = (vertexIndex - 1).clamp(0, wayNames.length - 1);
  return _cleanName(wayNames[segmentIndex]);
}

String? _nameAfter(int vertexIndex, int pointCount, List<String>? wayNames) {
  if (wayNames == null || wayNames.isEmpty || pointCount < 2) return null;
  if (wayNames.length == pointCount) {
    return _cleanName(wayNames[(vertexIndex + 1).clamp(0, pointCount - 1)]);
  }
  final segmentIndex = vertexIndex.clamp(0, wayNames.length - 1);
  return _cleanName(wayNames[segmentIndex]);
}

List<Maneuver> _mergeNameChangeManeuvers(List<Maneuver> raw) {
  final merged = <Maneuver>[];
  for (final maneuver in raw) {
    if (merged.isNotEmpty && maneuver.type == ManeuverType.straight) {
      final previous = merged.last;
      if (previous.type == ManeuverType.straight &&
          previous.roadName == maneuver.roadName) {
        continue;
      }
      final canMergeIntoTurn =
          previous.type != ManeuverType.depart &&
          previous.type != ManeuverType.arrive &&
          previous.type != ManeuverType.roundaboutEnter &&
          previous.type != ManeuverType.roundaboutExit &&
          previous.roadName == null &&
          maneuver.roadName != null &&
          maneuver.distFromStartM - previous.distFromStartM <= 40.0;
      if (canMergeIntoTurn) {
        merged[merged.length - 1] = Maneuver(
          type: previous.type,
          lat: previous.lat,
          lon: previous.lon,
          distFromStartM: previous.distFromStartM,
          instruction: _instructionFor(
            previous.type,
            maneuver.roadName,
            exitNumber: previous.exitNumber,
          ),
          roadName: maneuver.roadName,
          exitNumber: previous.exitNumber,
        );
        continue;
      }
    }
    merged.add(maneuver);
  }
  return merged;
}

class _RoundaboutEvent {
  final ManeuverType type;
  final int? exitNumber;

  const _RoundaboutEvent(this.type, this.exitNumber);
}

_RoundaboutEvent? _roundaboutEventAt(int index, List<_Roundabout> roundabouts) {
  for (final roundabout in roundabouts) {
    if (index == roundabout.entryIndex) {
      return const _RoundaboutEvent(ManeuverType.roundaboutEnter, null);
    }
    if (index == roundabout.exitIndex) {
      return _RoundaboutEvent(
        ManeuverType.roundaboutExit,
        roundabout.exitNumber,
      );
    }
  }
  return null;
}

bool _isInsideRoundabout(int index, List<_Roundabout> roundabouts) {
  for (final roundabout in roundabouts) {
    if (index > roundabout.entryIndex && index < roundabout.exitIndex)
      return true;
  }
  return false;
}

Maneuver _roundaboutManeuver(
  ManeuverType type,
  List<GeoPoint> points,
  List<double> cumulative,
  int index,
  String? roadName, {
  int? exitNumber,
}) {
  return Maneuver(
    type: type,
    lat: points[index].lat,
    lon: points[index].lon,
    distFromStartM: cumulative[index],
    instruction: _instructionFor(type, roadName, exitNumber: exitNumber),
    roadName: roadName,
    exitNumber: exitNumber,
  );
}

class _Roundabout {
  final int entryIndex;
  final int exitIndex;
  final int exitNumber;

  const _Roundabout(this.entryIndex, this.exitIndex, this.exitNumber);
}

class _CircleFit {
  final double centerX;
  final double centerY;
  final double radiusM;
  final double residualM;
  final double referenceLat;
  final double referenceLon;

  const _CircleFit(
    this.centerX,
    this.centerY,
    this.radiusM,
    this.residualM,
    this.referenceLat,
    this.referenceLon,
  );

  double distanceFromCenter(GeoPoint point) {
    final projected = _projectToLocal(point, referenceLat, referenceLon);
    final dx = projected.x - centerX;
    final dy = projected.y - centerY;
    return math.sqrt(dx * dx + dy * dy);
  }

  double bearingAroundCenter(GeoPoint point) {
    final projected = _projectToLocal(point, referenceLat, referenceLon);
    return _normalizeDegrees(
      math.atan2(projected.x - centerX, projected.y - centerY) *
          180.0 /
          math.pi,
    );
  }
}

class _LocalPoint {
  final double x;
  final double y;

  const _LocalPoint(this.x, this.y);
}

List<_Roundabout> _detectRoundabouts(
  List<GeoPoint> points,
  List<double> cumulative,
) {
  final roundabouts = <_Roundabout>[];
  if (points.length < 5) return roundabouts;

  final angles = List<double>.filled(points.length, 0.0);
  for (var i = 1; i < points.length - 1; i++) {
    angles[i] = signedTurnAngle(points[i - 1], points[i], points[i + 1]);
  }

  var i = 1;
  while (i < points.length - 1) {
    if (angles[i].abs() < 4.0) {
      i++;
      continue;
    }
    final sign = angles[i] > 0 ? 1 : -1;
    final start = i;
    while (i < points.length - 1 &&
        angles[i].abs() >= 4.0 &&
        ((angles[i] > 0 ? 1 : -1) == sign)) {
      i++;
    }
    final end = i - 1;
    if (end - start + 1 < 3) continue;

    final fit = _fitCircle(points.sublist(start, end + 1));
    if (fit == null ||
        fit.radiusM < 5.0 ||
        fit.radiusM > 150.0 ||
        fit.residualM > math.max(2.0, fit.radiusM * 0.15)) {
      continue;
    }

    final beforeIsSpoke =
        start > 0 &&
        fit.distanceFromCenter(points[start - 1]) > fit.radiusM * 1.25;
    final afterIsSpoke =
        end + 1 < points.length &&
        fit.distanceFromCenter(points[end + 1]) > fit.radiusM * 1.25;
    final entryIndex = beforeIsSpoke ? start : math.max(0, start - 1);
    final exitIndex = afterIsSpoke ? end : math.min(points.length - 1, end + 1);
    if (exitIndex - entryIndex < 2) continue;

    final sweep = _sweepAroundCircle(points, entryIndex, exitIndex, fit, sign);
    if (sweep < 45.0 || sweep > 360.0) continue;

    final arcLength = cumulative[exitIndex] - cumulative[entryIndex];
    final chord = points[entryIndex].distanceTo(points[exitIndex]);
    if (arcLength < 15.0 || (sweep < 350.0 && arcLength < chord * 1.03)) {
      continue;
    }

    final exitNumber = math.max(1, ((sweep + 45.0) / 90.0).floor());
    roundabouts.add(
      _Roundabout(entryIndex, exitIndex, math.min(exitNumber, 12)),
    );
  }
  return roundabouts;
}

double _sweepAroundCircle(
  List<GeoPoint> points,
  int entryIndex,
  int exitIndex,
  _CircleFit fit,
  int sign,
) {
  var total = 0.0;
  var previous = fit.bearingAroundCenter(points[entryIndex]);
  for (var i = entryIndex + 1; i <= exitIndex; i++) {
    final current = fit.bearingAroundCenter(points[i]);
    var delta = _normalizeSignedDegrees(current - previous);
    if (sign > 0 && delta < 0) delta += 360.0;
    if (sign < 0 && delta > 0) delta -= 360.0;
    total += delta;
    previous = current;
  }
  return total.abs();
}

_CircleFit? _fitCircle(List<GeoPoint> points) {
  if (points.length < 3) return null;
  final referenceLat =
      points.map((point) => point.lat).reduce((a, b) => a + b) / points.length;
  final referenceLon =
      points.map((point) => point.lon).reduce((a, b) => a + b) / points.length;
  final local = points
      .map((point) => _projectToLocal(point, referenceLat, referenceLon))
      .toList(growable: false);

  var sx = 0.0;
  var sy = 0.0;
  var sxx = 0.0;
  var syy = 0.0;
  var sxy = 0.0;
  var sz = 0.0;
  var sxz = 0.0;
  var syz = 0.0;
  for (final point in local) {
    final z = point.x * point.x + point.y * point.y;
    sx += point.x;
    sy += point.y;
    sxx += point.x * point.x;
    syy += point.y * point.y;
    sxy += point.x * point.y;
    sz += z;
    sxz += point.x * z;
    syz += point.y * z;
  }

  final matrix = <List<double>>[
    <double>[sxx, sxy, sx, -sxz],
    <double>[sxy, syy, sy, -syz],
    <double>[sx, sy, points.length.toDouble(), -sz],
  ];
  final solution = _solve3x3(matrix);
  if (solution == null) return null;

  final centerX = -solution[0] / 2.0;
  final centerY = -solution[1] / 2.0;
  final radiusSquared = centerX * centerX + centerY * centerY - solution[2];
  if (!radiusSquared.isFinite || radiusSquared <= 0.0) return null;
  final radius = math.sqrt(radiusSquared);

  var residualSquared = 0.0;
  for (final point in local) {
    final dx = point.x - centerX;
    final dy = point.y - centerY;
    final residual = math.sqrt(dx * dx + dy * dy) - radius;
    residualSquared += residual * residual;
  }
  return _CircleFit(
    centerX,
    centerY,
    radius,
    math.sqrt(residualSquared / points.length),
    referenceLat,
    referenceLon,
  );
}

List<double>? _solve3x3(List<List<double>> matrix) {
  for (var column = 0; column < 3; column++) {
    var pivotRow = column;
    for (var row = column + 1; row < 3; row++) {
      if (matrix[row][column].abs() > matrix[pivotRow][column].abs()) {
        pivotRow = row;
      }
    }
    if (matrix[pivotRow][column].abs() < 1e-9) return null;
    if (pivotRow != column) {
      final temp = matrix[column];
      matrix[column] = matrix[pivotRow];
      matrix[pivotRow] = temp;
    }
    final pivot = matrix[column][column];
    for (var c = column; c < 4; c++) {
      matrix[column][c] /= pivot;
    }
    for (var row = 0; row < 3; row++) {
      if (row == column) continue;
      final factor = matrix[row][column];
      for (var c = column; c < 4; c++) {
        matrix[row][c] -= factor * matrix[column][c];
      }
    }
  }
  return <double>[matrix[0][3], matrix[1][3], matrix[2][3]];
}

_LocalPoint _projectToLocal(
  GeoPoint point,
  double referenceLat,
  double referenceLon,
) {
  const earthRadiusM = 6371008.8;
  final x =
      _radians(point.lon - referenceLon) *
      math.cos(_radians(referenceLat)) *
      earthRadiusM;
  final y = _radians(point.lat - referenceLat) * earthRadiusM;
  return _LocalPoint(x, y);
}

double _radians(double degrees) => degrees * math.pi / 180.0;

double _normalizeDegrees(double degrees) {
  var normalized = degrees % 360.0;
  if (normalized < 0) normalized += 360.0;
  return normalized;
}

double _normalizeSignedDegrees(double degrees) {
  var normalized = _normalizeDegrees(degrees);
  if (normalized > 180.0) normalized -= 360.0;
  return normalized;
}
