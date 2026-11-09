/// Ride/track data model + statistics computation (SPEC §6).
library;

import 'api.dart';

/// A single recorded track sample. All units SI: meters, m/s, bpm, rpm, W, °C.
class TrackPoint {
  final DateTime t; // UTC
  final double lat, lon;
  final double? ele, speed, hr, cad, power, temp;

  const TrackPoint(this.t, this.lat, this.lon,
      {this.ele, this.speed, this.hr, this.cad, this.power, this.temp});

  TrackPoint copyWith(
          {DateTime? t,
          double? lat,
          double? lon,
          double? ele,
          double? speed,
          double? hr,
          double? cad,
          double? power,
          double? temp}) =>
      TrackPoint(t ?? this.t, lat ?? this.lat, lon ?? this.lon,
          ele: ele ?? this.ele,
          speed: speed ?? this.speed,
          hr: hr ?? this.hr,
          cad: cad ?? this.cad,
          power: power ?? this.power,
          temp: temp ?? this.temp);

  @override
  String toString() =>
      'TrackPoint($t, $lat, $lon, ele:$ele, spd:$speed, hr:$hr, cad:$cad, pwr:$power, temp:$temp)';
}

/// A pause window [start, end] in UTC. Segments overlapping a pause window
/// contribute neither time nor distance.
typedef PauseWindow = ({DateTime start, DateTime end});

/// A recorded ride with pre-computed [stats] (see [computeRideStats]).
class Ride {
  final String id;
  final DateTime started; // UTC
  final List<TrackPoint> points;
  final Map<String, num> stats;
  final List<PauseWindow> pauses;

  Ride(
      {required this.id,
      required this.started,
      required this.points,
      required this.stats,
      this.pauses = const []});

  double get distanceM => (stats['distanceM'] ?? 0).toDouble();
  double get totalTimeS => (stats['totalTimeS'] ?? 0).toDouble();

  @override
  String toString() =>
      'Ride($id, ${points.length} pts, ${distanceM.toStringAsFixed(1)} m, ${totalTimeS.toStringAsFixed(0)} s)';
}

/// Default rider profile used by the calorie models (no account / offline:
/// no user onboarding data is assumed; these are documented defaults).
class RiderProfile {
  final double weightKg;
  final int ageYears;
  final bool male;
  const RiderProfile({this.weightKg = 75.0, this.ageYears = 35, this.male = true});
}

/// Speed below which a segment counts as stopped (m/s).
const double kMovingSpeedThreshold = 0.5;

/// Computes the full statistics map for a ride.
///
/// [pausedTotal] is the accumulated wall-clock pause duration; it is
/// subtracted from elapsed time (pause intervals are also excluded from
/// distance implicitly, since the recorder emits no points while paused).
///
/// Keys (all present):
///   totalTimeS, movingTimeS, distanceM,
///   avgSpeedMps, maxSpeedMps, avgMovingSpeedMps,
///   elevationGainM, elevationLossM, minEleM, maxEleM,
///   avgHr, maxHr, avgCadence, maxCadence, avgPower, maxPower, avgTemp,
///   calories
/// Sensor averages are 0 when no samples exist.
Map<String, num> computeRideStats(List<TrackPoint> points,
    {Duration pausedTotal = Duration.zero,
    List<PauseWindow> pauses = const [],
    RiderProfile rider = const RiderProfile()}) {
  final stats = <String, num>{
    'totalTimeS': 0,
    'movingTimeS': 0,
    'distanceM': 0.0,
    'avgSpeedMps': 0.0,
    'maxSpeedMps': 0.0,
    'avgMovingSpeedMps': 0.0,
    'elevationGainM': 0.0,
    'elevationLossM': 0.0,
    'minEleM': 0.0,
    'maxEleM': 0.0,
    'avgHr': 0.0,
    'maxHr': 0.0,
    'avgCadence': 0.0,
    'maxCadence': 0.0,
    'avgPower': 0.0,
    'maxPower': 0.0,
    'avgTemp': 0.0,
    'calories': 0.0,
  };
  if (points.isEmpty) return stats;

  double dist = 0, movingS = 0, maxSpeed = 0, gain = 0, loss = 0, kcal = 0;
  double minEle = double.infinity, maxEle = -double.infinity;
  double hrSum = 0, cadSum = 0, pwrSum = 0, tempSum = 0;
  double maxHr = 0, maxCad = 0, maxPwr = 0;
  int hrN = 0, cadN = 0, pwrN = 0, tempN = 0;

  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    if (p.hr != null) {
      hrSum += p.hr!;
      hrN++;
      if (p.hr! > maxHr) maxHr = p.hr!;
    }
    if (p.cad != null) {
      cadSum += p.cad!;
      cadN++;
      if (p.cad! > maxCad) maxCad = p.cad!;
    }
    if (p.power != null) {
      pwrSum += p.power!;
      pwrN++;
      if (p.power! > maxPwr) maxPwr = p.power!;
    }
    if (p.temp != null) {
      tempSum += p.temp!;
      tempN++;
    }
    if (p.ele != null) {
      if (p.ele! < minEle) minEle = p.ele!;
      if (p.ele! > maxEle) maxEle = p.ele!;
    }
    if (p.speed != null && p.speed! > maxSpeed) maxSpeed = p.speed!;

    if (i == 0) continue;
    final prev = points[i - 1];
    final dtMs = p.t.difference(prev.t).inMilliseconds;
    if (dtMs <= 0) continue;
    // Segments bridging a pause window contribute neither time nor distance.
    if (_segmentPaused(prev.t, p.t, pauses)) continue;
    final dt = dtMs / 1000.0;
    final d = GeoPoint(prev.lat, prev.lon).distanceTo(GeoPoint(p.lat, p.lon));
    dist += d;
    // Segment speed: prefer recorded speed, else derive from geometry.
    final segSpeed = p.speed ?? (d / dt);
    final moving = segSpeed >= kMovingSpeedThreshold;
    if (moving) movingS += dt;
    if (p.ele != null && prev.ele != null) {
      final de = p.ele! - prev.ele!;
      if (de > 0) {
        gain += de;
      } else {
        loss -= de;
      }
    }
    // Calories: integrate per segment.
    final segHr =
        (p.hr != null && prev.hr != null) ? (p.hr! + prev.hr!) / 2.0 : (p.hr ?? prev.hr);
    if (segHr != null) {
      kcal += _keytelKcalPerMinute(segHr, rider) * (dt / 60.0);
    } else {
      kcal += _metForCyclingSpeed(segSpeed) * rider.weightKg * (dt / 3600.0);
    }
  }

  final totalS =
      (points.last.t.difference(points.first.t).inMilliseconds - pausedTotal.inMilliseconds)
              .toDouble() /
          1000.0;
  final clampedTotal = totalS > 0 ? totalS : 0.0;

  stats['totalTimeS'] = clampedTotal;
  stats['movingTimeS'] = movingS;
  stats['distanceM'] = dist;
  stats['avgSpeedMps'] = clampedTotal > 0 ? dist / clampedTotal : 0.0;
  stats['maxSpeedMps'] = maxSpeed;
  stats['avgMovingSpeedMps'] = movingS > 0 ? dist / movingS : 0.0;
  stats['elevationGainM'] = gain;
  stats['elevationLossM'] = loss;
  if (minEle != double.infinity) {
    stats['minEleM'] = minEle;
    stats['maxEleM'] = maxEle;
  }
  stats['avgHr'] = hrN > 0 ? hrSum / hrN : 0.0;
  stats['maxHr'] = maxHr;
  stats['avgCadence'] = cadN > 0 ? cadSum / cadN : 0.0;
  stats['maxCadence'] = maxCad;
  stats['avgPower'] = pwrN > 0 ? pwrSum / pwrN : 0.0;
  stats['maxPower'] = maxPwr;
  stats['avgTemp'] = tempN > 0 ? tempSum / tempN : 0.0;
  stats['calories'] = kcal;
  return stats;
}

/// True when the segment [a, b] overlaps any pause window.
bool _segmentPaused(DateTime a, DateTime b, List<PauseWindow> pauses) {
  for (final w in pauses) {
    if (a.isBefore(w.end) && b.isAfter(w.start)) return true;
  }
  return false;
}

/// Cumulative distances (meters) along [points], skipping segments that
/// overlap a pause window. Exported for the TCX/FIT writers.
List<double> cumulativeDistances(List<TrackPoint> points,
    {List<PauseWindow> pauses = const []}) {
  final out = List<double>.filled(points.length, 0.0);
  for (var i = 1; i < points.length; i++) {
    out[i] = out[i - 1];
    if (_segmentPaused(points[i - 1].t, points[i].t, pauses)) continue;
    out[i] += GeoPoint(points[i - 1].lat, points[i - 1].lon)
        .distanceTo(GeoPoint(points[i].lat, points[i].lon));
  }
  return out;
}

/// Keytel et al. (2005) HR-based energy expenditure, kcal per minute.
double _keytelKcalPerMinute(double hr, RiderProfile r) {
  final raw = r.male
      ? (-55.0969 + 0.6309 * hr + 0.1988 * r.weightKg + 0.2017 * r.ageYears) / 4.184
      : (-20.4022 + 0.4472 * hr - 0.1263 * r.weightKg + 0.0740 * r.ageYears) / 4.184;
  return raw < 0 ? 0 : raw;
}

/// MET estimate for cycling from speed (Compendium of Physical Activities).
double _metForCyclingSpeed(double mps) {
  final kmh = mps * 3.6;
  if (kmh < 16.0) return 4.0; // leisure
  if (kmh < 19.3) return 6.0; // 10-11.9 mph
  if (kmh < 22.5) return 8.0; // 12-13.9 mph
  if (kmh < 25.7) return 10.0; // 14-15.9 mph
  if (kmh < 32.2) return 12.0; // 16-19 mph
  return 16.0; // racing > 20 mph
}
