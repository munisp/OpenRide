import 'dart:math' as math;

import 'api.dart';
import 'maneuver.dart';

class NavState {
  final double distToNextManeuverM;
  final Maneuver? next;
  final double offRouteDistM;
  final bool rerouting;
  final double etaS;
  final double remainingM;

  const NavState({
    required this.distToNextManeuverM,
    required this.next,
    required this.offRouteDistM,
    required this.rerouting,
    required this.etaS,
    required this.remainingM,
  });
}

class Navigator {
  static const double maneuverTriggerM = 30.0;
  static const double offRouteThresholdM = 25.0;
  static const Duration offRouteSustained = Duration(seconds: 5);
  static const double minimumEtaSpeedMps = 1.0;
  static const double _distanceToleranceM = 0.05;

  final RouterEngine _engine;
  final Profile _profile;
  final DateTime Function() _clock;

  RouteResult? _currentRoute;

  RouteResult? get currentRoute => _currentRoute;

  set currentRoute(RouteResult? route) {
    if (route == null) {
      _clearRoute();
    } else {
      _installRoute(route);
    }
  }

  List<GeoPoint> _points = const <GeoPoint>[];
  List<double> _cumulativeM = const <double>[];
  List<Maneuver> _maneuvers = const <Maneuver>[];
  int _nextManeuverIndex = 0;
  int _segmentIndex = 0;
  double _routeDistanceM = 0.0;
  GeoPoint? _destination;

  final List<String> _voicePrompts = <String>[];
  final Set<int> _promptedAt200 = <int>{};
  final Set<int> _promptedAt50 = <int>{};
  final Set<int> _promptedAtManeuver = <int>{};

  DateTime? _offRouteSince;
  double _smoothedSpeedMps = 0.0;
  bool _hasSpeedSample = false;

  Navigator(
    RouteResult route,
    RouterEngine engine,
    Profile profile, {
    DateTime Function()? clock,
  }) : _engine = engine,
       _profile = profile,
       _clock = clock ?? DateTime.now {
    _installRoute(route);
  }

  NavState update(GeoPoint pos, double speedMps, double headingDeg) {
    if (_points.isEmpty) {
      return const NavState(
        distToNextManeuverM: 0.0,
        next: null,
        offRouteDistM: 0.0,
        rerouting: false,
        etaS: 0.0,
        remainingM: 0.0,
      );
    }

    var projection = _project(pos, headingDeg);
    var crossTrackM = projection.crossTrackM;
    final now = _clock().toUtc();
    var rerouteAttempted = false;

    if (crossTrackM > offRouteThresholdM) {
      _offRouteSince ??= now;
      if (now.difference(_offRouteSince!) > offRouteSustained) {
        rerouteAttempted = true;
        if (_reroute(pos)) {
          projection = _project(pos, headingDeg, global: true);
          crossTrackM = projection.crossTrackM;
        } else {
          _offRouteSince = now;
        }
      }
    } else {
      _offRouteSince = null;
    }

    _advanceManeuversAndQueuePrompts(projection.alongM);
    _updateSmoothedSpeed(speedMps);

    final next = _nextManeuver;
    final distanceToNext = next == null
        ? 0.0
        : math.max(0.0, next.distFromStartM - projection.alongM);
    final remainingM = math.max(0.0, _routeDistanceM - projection.alongM);
    final etaS = remainingM / math.max(minimumEtaSpeedMps, _smoothedSpeedMps);

    return NavState(
      distToNextManeuverM: distanceToNext,
      next: next,
      offRouteDistM: crossTrackM,
      rerouting: rerouteAttempted,
      etaS: etaS,
      remainingM: remainingM,
    );
  }

  List<String> drainVoicePrompts() {
    final prompts = List<String>.of(_voicePrompts);
    _voicePrompts.clear();
    return prompts;
  }

  Maneuver? get _nextManeuver => _nextManeuverIndex < _maneuvers.length
      ? _maneuvers[_nextManeuverIndex]
      : null;

  void _clearRoute() {
    _currentRoute = null;
    _points = const <GeoPoint>[];
    _cumulativeM = const <double>[];
    _maneuvers = const <Maneuver>[];
    _nextManeuverIndex = 0;
    _segmentIndex = 0;
    _routeDistanceM = 0.0;
    _destination = null;
    _voicePrompts.clear();
    _promptedAt200.clear();
    _promptedAt50.clear();
    _promptedAtManeuver.clear();
    _offRouteSince = null;
  }

  void _installRoute(RouteResult route) {
    _currentRoute = route;
    _points = List<GeoPoint>.of(route.points);
    _cumulativeM = cumulativeDistancesM(_points);
    _maneuvers = buildManeuvers(route);
    _nextManeuverIndex =
        _maneuvers.isNotEmpty && _maneuvers.first.type == ManeuverType.depart
        ? 1
        : 0;
    _segmentIndex = 0;
    _routeDistanceM = route.distM.isFinite && route.distM > 0.0
        ? route.distM
        : (_cumulativeM.isEmpty ? 0.0 : _cumulativeM.last);
    _destination = _points.isEmpty ? null : _points.last;
    _voicePrompts.clear();
    _promptedAt200.clear();
    _promptedAt50.clear();
    _promptedAtManeuver.clear();
    _offRouteSince = null;
  }

  bool _reroute(GeoPoint pos) {
    final destination = _destination;
    if (destination == null || pos.distanceTo(destination) < 1.0) return false;
    try {
      final replacement = _engine.route(
        RouteRequest(
          from: pos,
          to: destination,
          via: const <GeoPoint>[],
          profile: _profile,
          elevationFromSrtm: false,
        ),
      );
      if (replacement.points.isEmpty) return false;
      _installRoute(replacement);
      return true;
    } on Exception {
      return false;
    }
  }

  void _advanceManeuversAndQueuePrompts(double progressM) {
    var advanced = false;
    while (_nextManeuverIndex < _maneuvers.length) {
      final maneuver = _maneuvers[_nextManeuverIndex];
      final distanceM = maneuver.distFromStartM - progressM;
      if (distanceM > maneuverTriggerM + _distanceToleranceM) break;
      if (_promptedAtManeuver.add(_nextManeuverIndex)) {
        _voicePrompts.add(maneuver.instruction);
      }
      _nextManeuverIndex++;
      advanced = true;
    }
    if (advanced) return;

    final nextIndex = _nextManeuverIndex;
    if (nextIndex >= _maneuvers.length) return;
    final next = _maneuvers[nextIndex];
    final distanceM = next.distFromStartM - progressM;
    if (distanceM <= 200.0 + _distanceToleranceM &&
        _promptedAt200.add(nextIndex)) {
      _voicePrompts.add('In 200 meters, ${_lowerFirst(next.instruction)}');
    }
    if (distanceM <= 50.0 + _distanceToleranceM &&
        _promptedAt50.add(nextIndex)) {
      _voicePrompts.add('In 50 meters, ${_lowerFirst(next.instruction)}');
    }
  }

  String _lowerFirst(String text) =>
      text.isEmpty ? text : '${text[0].toLowerCase()}${text.substring(1)}';

  void _updateSmoothedSpeed(double speedMps) {
    if (!speedMps.isFinite) return;
    final speed = math.max(0.0, speedMps);
    _smoothedSpeedMps = _hasSpeedSample
        ? 0.35 * speed + 0.65 * _smoothedSpeedMps
        : speed;
    _hasSpeedSample = true;
  }

  _Projection _project(GeoPoint pos, double headingDeg, {bool global = false}) {
    if (_points.length < 2) {
      return _Projection(0, 0.0, 0.0, pos, 0.0);
    }
    final lastSegment = _points.length - 2;
    final windowStart = global ? 0 : math.max(0, _segmentIndex - 4);
    final windowEnd = global
        ? lastSegment
        : math.min(lastSegment, _segmentIndex + 12);
    var best = _scanSegments(pos, headingDeg, windowStart, windowEnd);

    if (!global) {
      final globalBest = _scanSegments(pos, headingDeg, 0, lastSegment);
      if (globalBest.crossTrackM + 0.5 < best.crossTrackM) best = globalBest;
    }
    _segmentIndex = best.segmentIndex;
    return best;
  }

  _Projection _scanSegments(
    GeoPoint pos,
    double headingDeg,
    int startSegment,
    int endSegment,
  ) {
    _Projection? best;
    var bestScore = double.infinity;
    for (var i = startSegment; i <= endSegment; i++) {
      final candidate = _projectOntoSegment(pos, i);
      final score =
          candidate.crossTrackM +
          _headingPenalty(candidate.segmentBearingDeg, headingDeg);
      if (score < bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best ?? _Projection(0, 0.0, double.infinity, pos, 0.0);
  }

  double _headingPenalty(double segmentBearingDeg, double headingDeg) {
    if (!headingDeg.isFinite) return 0.0;
    final difference = _normalizeSignedDegrees(headingDeg - segmentBearingDeg)
        .abs();
    if (difference > 120.0) return 4.0;
    if (difference > 90.0) return 2.0;
    return 0.0;
  }

  _Projection _projectOntoSegment(GeoPoint pos, int segmentIndex) {
    const earthRadiusM = 6371008.8;
    final start = _points[segmentIndex];
    final end = _points[segmentIndex + 1];
    final referenceLat = _radians(start.lat);
    final cosReference = math.cos(referenceLat).abs() < 1e-12
        ? 1e-12
        : math.cos(referenceLat);
    final ax = 0.0;
    final ay = 0.0;
    final bx = _radians(end.lon - start.lon) * cosReference * earthRadiusM;
    final by = _radians(end.lat - start.lat) * earthRadiusM;
    final px = _radians(pos.lon - start.lon) * cosReference * earthRadiusM;
    final py = _radians(pos.lat - start.lat) * earthRadiusM;
    final vx = bx - ax;
    final vy = by - ay;
    final lengthSquared = vx * vx + vy * vy;
    final t = lengthSquared <= 1e-12
        ? 0.0
        : (((px - ax) * vx + (py - ay) * vy) / lengthSquared).clamp(0.0, 1.0);
    final projectedX = ax + t * vx;
    final projectedY = ay + t * vy;
    final dx = px - projectedX;
    final dy = py - projectedY;
    final crossTrackM = math.sqrt(dx * dx + dy * dy);
    final segmentLengthM = math.sqrt(lengthSquared);
    final alongM = _cumulativeM[segmentIndex] + segmentLengthM * t;
    final projectedLat =
        start.lat + (projectedY / earthRadiusM) * 180.0 / math.pi;
    final projectedLon =
        start.lon +
        (projectedX / (earthRadiusM * cosReference)) * 180.0 / math.pi;
    return _Projection(
      segmentIndex,
      alongM,
      crossTrackM,
      GeoPoint(projectedLat, projectedLon),
      start.bearingTo(end),
    );
  }

  double _radians(double degrees) => degrees * math.pi / 180.0;

  double _normalizeSignedDegrees(double degrees) {
    var normalized = degrees % 360.0;
    if (normalized < -180.0) normalized += 360.0;
    if (normalized > 180.0) normalized -= 360.0;
    return normalized;
  }
}

class _Projection {
  final int segmentIndex;
  final double alongM;
  final double crossTrackM;
  final GeoPoint point;
  final double segmentBearingDeg;

  const _Projection(
    this.segmentIndex,
    this.alongM,
    this.crossTrackM,
    this.point,
    this.segmentBearingDeg,
  );
}
