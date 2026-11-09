/// Zero-dependency test harness + ride_core test suite (SPEC §8).
///
/// Run: /tmp/dart-sdk/bin/dart run test/run_tests.dart
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../lib/ride_core.dart';
import 'package:ride_core/testing/fit_reader.dart';
import 'xml_reader.dart';

// ---------------------------------------------------------------- harness
int _pass = 0;
int _fail = 0;
final _failures = <String>[];

Future<void> t(String name, FutureOr<bool> Function() f) async {
  try {
    final ok = await f();
    if (ok) {
      _pass++;
      stdout.writeln('PASS $name');
    } else {
      _fail++;
      _failures.add(name);
      stdout.writeln('FAIL $name');
    }
  } catch (e, st) {
    _fail++;
    _failures.add('$name ($e)');
    stdout.writeln('FAIL $name  [$e]\n$st');
  }
}

void expectEq(Object? a, Object? b, [String what = '']) {
  if (a != b) throw StateError('expectEq failed $what: $a != $b');
}

void expectClose(double a, double b, double tol, [String what = '']) {
  if ((a - b).abs() > tol) {
    throw StateError('expectClose failed $what: $a not within $tol of $b');
  }
}

void expectTrue(bool v, [String what = '']) {
  if (!v) throw StateError('expectTrue failed $what');
}

// Deterministic gaussian noise (LCG + Box-Muller).
class Noise {
  int _s;
  double? _spare;
  Noise([this._s = 42]);
  double _u() {
    _s = (_s * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF;
    return (_s >> 11) / 9007199254740992.0;
  }

  double gauss() {
    if (_spare != null) {
      final v = _spare!;
      _spare = null;
      return v;
    }
    final u1 = _u().clamp(1e-12, 1.0);
    final u2 = _u();
    final r = math.sqrt(-2 * math.log(u1));
    _spare = r * math.sin(2 * math.pi * u2);
    return r * math.cos(2 * math.pi * u2);
  }
}

// ---------------------------------------------------------------- fixtures
const _t0ms = 1717228800000; // 2024-06-01T08:00:00.000Z

DateTime atS(double seconds) =>
    DateTime.fromMillisecondsSinceEpoch(_t0ms + (seconds * 1000).round(), isUtc: true);

/// Builds a ride along a straight northward line with full sensor data.
Ride sampleRide({int n = 20, double dtS = 1.0, double mPerStep = 8.0}) {
  final pts = <TrackPoint>[];
  var lat = 52.0;
  const lon = 13.0;
  var ele = 100.0;
  for (var i = 0; i < n; i++) {
    pts.add(TrackPoint(
      atS(i * dtS),
      lat,
      lon,
      ele: ele,
      speed: mPerStep / dtS,
      hr: 120.0 + i,
      cad: 80.0 + (i % 3),
      power: 180.0 + i * 2,
      temp: 18.0 + i * 0.1,
    ));
    lat += mPerStep / 111320.0;
    ele += (i % 4 == 3) ? -1.0 : 2.0; // gains and losses
  }
  final stats = computeRideStats(pts);
  return Ride(id: 'test-ride-1', started: pts.first.t, points: pts, stats: stats);
}

// ---------------------------------------------------------------- tests
Future<void> main() async {
  // ---- stats ----
  await t('stats: distance/time/speed/elevation/sensors', () {
    final pts = <TrackPoint>[];
    var lat = 52.0;
    for (var i = 0; i < 3; i++) {
      pts.add(TrackPoint(atS(i.toDouble()), lat, 13.0,
          ele: 100.0 + [0, 10, 5][i], speed: 10.0, hr: 150, cad: 90, power: 200));
      lat += 10.0 / 111320.0; // ~10 m per step
    }
    final s = computeRideStats(pts);
    final expectedDist = 2 *
        GeoPoint(52.0, 13.0)
            .distanceTo(GeoPoint(52.0 + 10.0 / 111320.0, 13.0));
    expectClose(s['distanceM']!.toDouble(), expectedDist, 0.01, 'distance');
    expectClose(s['totalTimeS']!.toDouble(), 2.0, 1e-9, 'totalTime');
    expectClose(s['movingTimeS']!.toDouble(), 2.0, 1e-9, 'movingTime');
    expectClose(s['avgSpeedMps']!.toDouble(), expectedDist / 2, 0.01, 'avgSpeed');
    expectClose(s['maxSpeedMps']!.toDouble(), 10.0, 1e-9, 'maxSpeed');
    expectClose(s['elevationGainM']!.toDouble(), 10.0, 1e-9, 'gain');
    expectClose(s['elevationLossM']!.toDouble(), 5.0, 1e-9, 'loss');
    expectClose(s['avgHr']!.toDouble(), 150.0, 1e-9, 'avgHr');
    expectClose(s['maxHr']!.toDouble(), 150.0, 1e-9, 'maxHr');
    expectClose(s['avgCadence']!.toDouble(), 90.0, 1e-9, 'avgCad');
    expectClose(s['maxPower']!.toDouble(), 200.0, 1e-9, 'maxPower');
    // Keytel (male, 75 kg, 35 y, HR 150): 14.7008 kcal/min -> 2 s = 0.4900
    expectClose(s['calories']!.toDouble(), 14.7008 * 2 / 60, 0.002, 'keytel kcal');
    return true;
  });

  await t('stats: MET calorie model without HR', () {
    final kmh25 = 25.0 / 3.6; // -> MET 10
    final pts = [
      TrackPoint(atS(0), 52.0, 13.0, speed: kmh25),
      TrackPoint(atS(3600), 52.0 + 25000 / 111320.0, 13.0, speed: kmh25),
    ];
    final s = computeRideStats(pts);
    expectClose(s['calories']!.toDouble(), 10.0 * 75.0 * 1.0, 1.0, 'MET kcal');
    expectClose(s['totalTimeS']!.toDouble(), 3600.0, 1e-6);
    return true;
  });

  await t('stats: paused time excluded from total', () {
    final pts = [
      TrackPoint(atS(0), 52.0, 13.0, speed: 5),
      TrackPoint(atS(10), 52.0001, 13.0, speed: 5),
      TrackPoint(atS(60), 52.0002, 13.0, speed: 5), // 40 s pause in between
    ];
    final s = computeRideStats(pts, pausedTotal: const Duration(seconds: 40));
    expectClose(s['totalTimeS']!.toDouble(), 20.0, 1e-9, 'total minus pause');
    return true;
  });

  // ---- Kalman ----
  await t('kalman: rejects synthetic 100 m jump outlier', () {
    final kf = GpsKalmanFilter();
    final noise = Noise(7);
    var rejected = 0;
    double maxDev = 0;
    for (var i = 0; i < 120; i++) {
      final trueLat = 52.0 + i * 8.0 / 111320.0;
      var measLat = trueLat + noise.gauss() * 5.0 / 111320.0;
      if (i == 60) measLat += 100.0 / 111320.0; // 100 m jump
      final r = kf.update(atS(i.toDouble()), measLat, 13.0, accuracy: 5.0);
      if (!r.accepted) rejected++;
      if (i == 60 || i == 61) {
        final devM = (r.lat - trueLat).abs() * 111320.0;
        if (devM > maxDev) maxDev = devM;
      }
    }
    expectEq(rejected, 1, 'exactly one rejection');
    expectTrue(maxDev < 20.0, 'filtered position ignores jump, dev=$maxDev m');
    return true;
  });

  await t('kalman: smooths jitter (RMSE reduction)', () {
    final kf = GpsKalmanFilter();
    final noise = Noise(99);
    var rawErr2 = 0.0, filtErr2 = 0.0;
    const n = 200;
    for (var i = 0; i < n; i++) {
      final trueLat = 52.0 + i * 8.0 / 111320.0;
      final meas = trueLat + noise.gauss() * 6.0 / 111320.0;
      final r = kf.update(atS(i.toDouble()), meas, 13.0, accuracy: 6.0);
      if (i > 20) {
        // skip warm-up
        rawErr2 += math.pow((meas - trueLat) * 111320.0, 2);
        filtErr2 += math.pow((r.lat - trueLat) * 111320.0, 2);
      }
    }
    final rawRmse = math.sqrt(rawErr2 / (n - 21));
    final filtRmse = math.sqrt(filtErr2 / (n - 21));
    expectTrue(filtRmse < rawRmse * 0.75,
        'filtered RMSE $filtRmse should be < 75% of raw $rawRmse');
    return true;
  });

  // ---- recorder ----
  await t('recorder: pause excludes time AND distance', () {
    var nowMs = _t0ms;
    final rec = RideRecorder(
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true));
    rec.start();
    // 10 s of riding at 10 m/s (1 fix/s)
    for (var i = 0; i <= 10; i++) {
      rec.addGps(atS(i.toDouble()), 52.0 + i * 10.0 / 111320.0, 13.0, accuracy: 4);
    }
    nowMs += 10 * 1000;
    rec.pause();
    // GPS keeps arriving while paused; rider keeps moving (should be ignored)
    for (var i = 11; i <= 19; i++) {
      rec.addGps(atS(i.toDouble()), 52.0 + i * 10.0 / 111320.0, 13.0, accuracy: 4);
    }
    nowMs += 10 * 1000; // pause window: t=10s .. t=20s
    rec.resume();
    for (var i = 20; i <= 30; i++) {
      rec.addGps(atS(i.toDouble()), 52.0 + i * 10.0 / 111320.0, 13.0, accuracy: 4);
    }
    nowMs += 11 * 1000;
    final ride = rec.stop();
    expectEq(ride.points.length, 22, 'points while recording only');
    expectClose(ride.stats['totalTimeS']!.toDouble(), 20.0, 1e-6, 'total excludes pause');
    expectClose(ride.stats['distanceM']!.toDouble(), 200.0, 25.0,
        'distance excludes paused segment');
    expectEq(rec.state, RecorderState.idle);
    return true;
  });

  await t('recorder: state machine guards', () {
    final rec = RideRecorder(clock: () => atS(0));
    var threw = false;
    try {
      rec.pause();
    } on StateError {
      threw = true;
    }
    expectTrue(threw, 'pause from idle throws');
    threw = false;
    try {
      rec.addGps(atS(0), 52, 13);
    } on StateError {
      threw = true;
    }
    expectTrue(threw, 'addGps from idle throws');
    rec.start();
    rec.pause();
    rec.resume();
    rec.pause();
    threw = false;
    try {
      rec.pause();
    } on StateError {
      threw = true;
    }
    expectTrue(threw, 'double pause throws');
    final ride = rec.stop();
    expectEq(ride.points.length, 0);
    return true;
  });

  await t('recorder: sensor channels attach via interpolation', () {
    var nowMs = _t0ms;
    final rec = RideRecorder(
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true));
    rec.start();
    rec.addSensorAt(SensorKind.heartRate, 100, atS(5));
    rec.addSensorAt(SensorKind.heartRate, 120, atS(15));
    rec.addSensorAt(SensorKind.power, 200, atS(9));
    rec.addSensorAt(SensorKind.power, 300, atS(11));
    rec.addSensorAt(SensorKind.temperature, 21.5, atS(9));
    rec.addSensorAt(SensorKind.barometricElevation, 100, atS(9));
    rec.addSensorAt(SensorKind.barometricElevation, 110, atS(11));
    // track point at t=10 -> hr interpolates to 110, power to 250, ele 105
    rec.addGps(atS(10), 52.0, 13.0, accuracy: 4);
    // late hr sample at t=12 attaches as nearest (stale window 10 s)
    rec.addSensorAt(SensorKind.heartRate, 130, atS(12));
    nowMs += 13 * 1000;
    final ride = rec.stop();
    final p = ride.points.single;
    expectClose(p.hr!, 110.0, 1e-9, 'hr interpolated at point time');
    expectClose(p.power!, 250.0, 1e-9, 'power interpolated');
    expectClose(p.ele!, 105.0, 1e-9, 'baro ele interpolated');
    expectClose(p.temp!, 21.5, 1e-9, 'temp nearest-hold');
    return true;
  });

  await t('recorder: outlier fix rejected, rejectedFixes counted', () {
    final rec = RideRecorder(clock: () => atS(0));
    rec.start();
    for (var i = 0; i <= 10; i++) {
      rec.addGps(atS(i.toDouble()), 52.0 + i * 5.0 / 111320.0, 13.0, accuracy: 4);
    }
    rec.addGps(atS(11), 52.0 + 1010.0 / 111320.0, 13.0, accuracy: 4); // jump
    rec.addGps(atS(12), 52.0 + 11 * 5.0 / 111320.0, 13.0, accuracy: 4);
    final ride = rec.stop();
    expectEq(rec.rejectedFixes, 1, 'one rejected fix');
    expectEq(ride.points.length, 12, '12 accepted points');
    return true;
  });

  // ---- GPX round-trip ----
  await t('gpx: parse-back field equality', () {
    final ride = sampleRide();
    final doc = parseXml(toGpx(ride));
    final root = doc.root;
    expectEq(root.name, 'gpx');
    expectEq(root.attr('version'), '1.1');
    final trk = root.find('trk')!;
    final seg = trk.find('trkseg')!;
    final trkpts = seg.findAll('trkpt');
    expectEq(trkpts.length, ride.points.length, 'trkpt count');
    final mdTime = root.find('metadata')!.find('time')!;
    expectEq(DateTime.parse(mdTime.text.trim()).millisecondsSinceEpoch,
        ride.started.millisecondsSinceEpoch, 'metadata time');
    for (var i = 0; i < trkpts.length; i++) {
      final el = trkpts[i];
      final p = ride.points[i];
      expectClose(double.parse(el.attr('lat')), p.lat, 5e-8, 'lat[$i]');
      expectClose(double.parse(el.attr('lon')), p.lon, 5e-8, 'lon[$i]');
      expectClose(el.find('ele')!.textDouble, p.ele!, 0.051, 'ele[$i]');
      expectEq(DateTime.parse(el.find('time')!.text.trim()).millisecondsSinceEpoch,
          p.t.millisecondsSinceEpoch, 'time[$i]');
      final ext = el.find('extensions')!.find('gpxtpx:TrackPointExtension')!;
      expectEq(ext.find('gpxtpx:hr')!.textInt, p.hr!.round(), 'hr[$i]');
      expectEq(ext.find('gpxtpx:cad')!.textInt, p.cad!.round(), 'cad[$i]');
      expectClose(ext.find('gpxtpx:atemp')!.textDouble, p.temp!, 0.051, 'atemp[$i]');
      expectEq(ext.find('ns3:power')!.textInt, p.power!.round(), 'power[$i]');
    }
    return true;
  });

  await t('gpx: point without sensors has no extensions', () {
    final pts = [TrackPoint(atS(0), 52.0, 13.0)];
    final ride =
        Ride(id: 'bare', started: pts.first.t, points: pts, stats: computeRideStats(pts));
    final doc = parseXml(toGpx(ride));
    final trkpt = doc.root.find('trk')!.find('trkseg')!.find('trkpt')!;
    expectTrue(trkpt.find('extensions') == null, 'no extensions element');
    expectTrue(trkpt.find('ele') == null, 'no ele element');
    return true;
  });

  // ---- TCX round-trip ----
  await t('tcx: parse-back field equality', () {
    final ride = sampleRide();
    final doc = parseXml(toTcx(ride));
    final root = doc.root;
    expectEq(root.name, 'TrainingCenterDatabase');
    final act = root.find('Activities')!.find('Activity')!;
    expectEq(act.attr('Sport'), 'Biking');
    expectEq(DateTime.parse(act.find('Id')!.text.trim()).millisecondsSinceEpoch,
        ride.started.millisecondsSinceEpoch, 'Activity Id');
    final lap = act.find('Lap')!;
    expectEq(DateTime.parse(lap.attr('StartTime')).millisecondsSinceEpoch,
        ride.started.millisecondsSinceEpoch, 'Lap StartTime');
    expectClose(lap.find('TotalTimeSeconds')!.textDouble,
        ride.stats['totalTimeS']!.toDouble(), 0.001, 'lap total time');
    expectClose(lap.find('DistanceMeters')!.textDouble,
        ride.stats['distanceM']!.toDouble(), 0.01, 'lap distance');
    expectClose(lap.find('MaximumSpeed')!.textDouble,
        ride.stats['maxSpeedMps']!.toDouble(), 0.001, 'lap max speed');
    expectEq(lap.find('Calories')!.textInt, ride.stats['calories']!.round());
    expectEq(lap.find('AverageHeartRateBpm')!.find('Value')!.textInt,
        ride.stats['avgHr']!.round(), 'lap avg hr');
    expectEq(lap.find('Intensity')!.text.trim(), 'Active');
    expectEq(lap.find('TriggerMethod')!.text.trim(), 'Manual');
    final tps = lap.find('Track')!.findAll('Trackpoint');
    expectEq(tps.length, ride.points.length, 'trackpoint count');
    var cum = 0.0;
    for (var i = 0; i < tps.length; i++) {
      final el = tps[i];
      final p = ride.points[i];
      if (i > 0) {
        final prev = ride.points[i - 1];
        cum += GeoPoint(prev.lat, prev.lon).distanceTo(GeoPoint(p.lat, p.lon));
      }
      expectEq(DateTime.parse(el.find('Time')!.text.trim()).millisecondsSinceEpoch,
          p.t.millisecondsSinceEpoch, 'tp time[$i]');
      final pos = el.find('Position')!;
      expectClose(pos.find('LatitudeDegrees')!.textDouble, p.lat, 5e-8, 'tp lat[$i]');
      expectClose(pos.find('LongitudeDegrees')!.textDouble, p.lon, 5e-8, 'tp lon[$i]');
      expectClose(el.find('AltitudeMeters')!.textDouble, p.ele!, 0.051, 'tp alt[$i]');
      expectClose(el.find('DistanceMeters')!.textDouble, cum, 0.02, 'tp dist[$i]');
      expectEq(el.find('HeartRateBpm')!.find('Value')!.textInt, p.hr!.round(), 'tp hr[$i]');
      expectEq(el.find('Cadence')!.textInt, p.cad!.round(), 'tp cad[$i]');
      final tpx = el.find('Extensions')!.find('ns3:TPX')!;
      expectEq(tpx.find('ns3:Watts')!.textInt, p.power!.round(), 'tp watts[$i]');
      expectClose(tpx.find('ns3:Speed')!.textDouble, p.speed!, 0.001, 'tp speed[$i]');
    }
    final lx = lap.find('Extensions')!.find('ns3:LX')!;
    expectClose(lx.find('ns3:AvgSpeed')!.textDouble,
        ride.stats['avgMovingSpeedMps']!.toDouble(), 0.001, 'lap LX avg speed');
    return true;
  });

  // ---- FIT round-trip ----
  await t('fit: header + CRCs + message structure', () {
    final ride = sampleRide();
    final bytes = toFit(ride);
    final f = parseFit(bytes); // throws on any CRC/size violation
    expectEq(f.protocolVersion, 0x10);
    final fileId = f.ofType(0);
    expectEq(fileId.length, 1, 'one file_id');
    expectEq(fileId.first[0], 4, 'file_id type=activity');
    expectEq(f.ofType(19).length, 1, 'one lap');
    expectEq(f.ofType(18).length, 1, 'one session');
    final act = f.ofType(34);
    expectEq(act.length, 1, 'one activity');
    expectEq(act.first[1], 1, 'num_sessions=1');
    expectEq(act.first[2], 0, 'activity type=manual');
    expectEq(act.first[0], (ride.stats['totalTimeS']! * 1000).round(),
        'activity total_timer_time ms');
    return true;
  });

  await t('fit: record round-trip positions/sensors', () {
    final ride = sampleRide();
    final f = parseFit(toFit(ride));
    final records = f.ofType(20);
    expectEq(records.length, ride.points.length, 'record count');
    var cum = 0.0;
    for (var i = 0; i < records.length; i++) {
      final m = records[i];
      final p = ride.points[i];
      if (i > 0) {
        final prev = ride.points[i - 1];
        cum += GeoPoint(prev.lat, prev.lon).distanceTo(GeoPoint(p.lat, p.lon));
      }
      // timestamps: FIT second resolution
      final ts = FitFile.fitTimeToUtc(m[253]);
      expectTrue(
          (ts.millisecondsSinceEpoch - p.t.millisecondsSinceEpoch).abs() <= 1000,
          'record time[$i]');
      // positions: semicircle rounding ~4.2e-8 deg
      expectClose(FitFile.semicirclesToDeg(m[0]), p.lat, 1e-7, 'record lat[$i]');
      expectClose(FitFile.semicirclesToDeg(m[1]), p.lon, 1e-7, 'record lon[$i]');
      expectClose(m.scaled(2, 5, 500), p.ele!, 0.21, 'record alt[$i]');
      expectEq(m[3], p.hr!.round(), 'record hr[$i]');
      expectEq(m[4], p.cad!.round(), 'record cad[$i]');
      expectClose(m.scaled(5, 100), cum, 0.02, 'record distance[$i]');
      expectClose(m.scaled(6, 1000), p.speed!, 0.001, 'record speed[$i]');
      expectEq(m[7], p.power!.round(), 'record power[$i]');
      expectEq(m[13], p.temp!.round(), 'record temp[$i]');
    }
    return true;
  });

  await t('fit: lap/session summary fields', () {
    final ride = sampleRide();
    final f = parseFit(toFit(ride));
    final lap = f.ofType(19).first;
    expectEq(lap[254], 0, 'lap message_index');
    expectEq(lap[25], 2, 'lap sport=cycling');
    expectEq(lap[24], 7, 'lap_trigger session_end');
    expectClose(lap.scaled(9, 100), ride.stats['distanceM']!.toDouble(), 0.05,
        'lap distance');
    expectEq(lap[7], (ride.stats['totalTimeS']! * 1000).round(), 'lap elapsed ms');
    expectEq(lap[8], (ride.stats['totalTimeS']! * 1000).round(), 'lap timer ms');
    expectClose(FitFile.semicirclesToDeg(lap[3]), ride.points.first.lat, 1e-7,
        'lap start lat');
    expectClose(FitFile.semicirclesToDeg(lap[5]), ride.points.last.lat, 1e-7,
        'lap end lat');
    expectEq(lap[16], ride.stats['maxHr']!.round(), 'lap max hr');
    expectEq(lap[20], ride.stats['maxPower']!.round(), 'lap max power');
    expectEq(lap[21], ride.stats['elevationGainM']!.round(), 'lap ascent');
    expectEq(lap[22], ride.stats['elevationLossM']!.round(), 'lap descent');

    final s = f.ofType(18).first;
    expectEq(s[5], 2, 'session sport=cycling');
    expectEq(s[26], 1, 'num_laps=1');
    expectEq(s[25], 0, 'first_lap_index=0');
    expectClose(s.scaled(9, 100), ride.stats['distanceM']!.toDouble(), 0.05,
        'session distance');
    expectClose(s.scaled(14, 1000), ride.stats['avgSpeedMps']!.toDouble(), 0.001,
        'session avg speed');
    expectClose(s.scaled(15, 1000), ride.stats['maxSpeedMps']!.toDouble(), 0.001,
        'session max speed');
    expectEq(s[11], ride.stats['calories']!.round(), 'session calories');
    expectEq(FitFile.fitTimeToUtc(s[2]).millisecondsSinceEpoch,
        ride.started.millisecondsSinceEpoch, 'session start_time');
    // bounds sanity: nec >= swc
    expectTrue(FitFile.semicirclesToDeg(s[29]) >= FitFile.semicirclesToDeg(s[31]),
        'nec_lat >= swc_lat');
    return true;
  });

  // ---- RideStore ----
  await t('store: save/list/load/delete round-trip', () async {
    final dir = await Directory.systemTemp.createTemp('ridestore_test');
    try {
      final store = RideStore(dir.path);
      final ride = sampleRide();
      await store.save(ride);
      final list = store.list();
      expectEq(list.length, 1);
      expectEq(list.first.id, ride.id);
      expectClose(list.first.distanceM, ride.stats['distanceM']!.toDouble(), 1e-9);
      expectEq(list.first.pointCount, ride.points.length);

      final loaded = await store.load(ride.id);
      expectEq(loaded.id, ride.id);
      expectEq(loaded.started.millisecondsSinceEpoch,
          ride.started.millisecondsSinceEpoch);
      expectEq(loaded.points.length, ride.points.length);
      for (var i = 0; i < loaded.points.length; i++) {
        final a = loaded.points[i];
        final b = ride.points[i];
        expectEq(a.t.millisecondsSinceEpoch, b.t.millisecondsSinceEpoch, 'pt t[$i]');
        expectClose(a.lat, b.lat, 6e-8, 'pt lat[$i]');
        expectClose(a.lon, b.lon, 6e-8, 'pt lon[$i]');
        expectClose(a.ele!, b.ele!, 0.0051, 'pt ele[$i]');
        expectClose(a.speed!, b.speed!, 0.0051, 'pt speed[$i]');
        expectEq(a.hr, b.hr, 'pt hr[$i]');
        expectEq(a.cad, b.cad, 'pt cad[$i]');
        expectEq(a.power, b.power, 'pt power[$i]');
        expectClose(a.temp!, b.temp!, 0.051, 'pt temp[$i]');
      }
      expectClose(loaded.stats['distanceM']!.toDouble(),
          ride.stats['distanceM']!.toDouble(), 1e-9, 'loaded stats distance');
      expectClose(loaded.stats['calories']!.toDouble(),
          ride.stats['calories']!.toDouble(), 1e-9, 'loaded stats calories');

      // second ride + delete
      final ride2 = sampleRide(n: 5);
      final ride2b =
          Ride(id: 'test-ride-2', started: ride2.started, points: ride2.points, stats: ride2.stats);
      await store.save(ride2b);
      expectEq(store.list().length, 2);
      store.delete(ride.id);
      final after = store.list();
      expectEq(after.length, 1);
      expectEq(after.first.id, 'test-ride-2');
      expectTrue(!File('${dir.path}/rides/${ride.id}.trk').existsSync(),
          'trk file deleted');
      return true;
    } finally {
      await dir.delete(recursive: true);
    }
  });

  await t('store: crash recovery ignores partial trailing record', () async {
    final dir = await Directory.systemTemp.createTemp('ridestore_crash');
    try {
      final store = RideStore(dir.path);
      final ride = sampleRide(n: 10);
      await store.save(ride);
      final file = File('${dir.path}/rides/${ride.id}.trk');
      final good = await file.length();
      // simulate crash mid-append: garbage + truncated frame
      final raf = await file.open(mode: FileMode.append);
      await raf.writeFrom([0x09, 0x40, 0x01, 0x05]); // claims 64-byte frame, only 2 bytes
      await raf.writeFrom([0xAA, 0xBB]);
      await raf.close();
      final loaded = await store.load(ride.id);
      expectEq(loaded.points.length, ride.points.length, 'all good records survive');
      expectClose(loaded.stats['distanceM']!.toDouble(),
          ride.stats['distanceM']!.toDouble(), 1e-9);
      expectTrue(await file.length() > good, 'file still has garbage tail');
      return true;
    } finally {
      await dir.delete(recursive: true);
    }
  });

  await t('store: pause windows persist across save/load', () async {
    var nowMs = _t0ms;
    final rec = RideRecorder(
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true));
    rec.start();
    for (var i = 0; i <= 10; i++) {
      rec.addGps(atS(i.toDouble()), 52.0 + i * 10.0 / 111320.0, 13.0, accuracy: 4);
    }
    nowMs += 10 * 1000;
    rec.pause();
    nowMs += 10 * 1000;
    rec.resume();
    for (var i = 20; i <= 30; i++) {
      rec.addGps(atS(i.toDouble()), 52.0 + i * 10.0 / 111320.0, 13.0, accuracy: 4);
    }
    nowMs += 11 * 1000;
    final ride = rec.stop();
    final dir = await Directory.systemTemp.createTemp('ridestore_pause');
    try {
      final store = RideStore(dir.path);
      await store.save(ride);
      final loaded = await store.load(ride.id);
      expectEq(loaded.pauses.length, 1, 'pause window persisted');
      expectEq(loaded.pauses.first.start.millisecondsSinceEpoch,
          ride.pauses.first.start.millisecondsSinceEpoch);
      expectEq(loaded.pauses.first.end.millisecondsSinceEpoch,
          ride.pauses.first.end.millisecondsSinceEpoch);
      expectClose(loaded.stats['distanceM']!.toDouble(),
          ride.stats['distanceM']!.toDouble(), 1e-9, 'paused distance survives');
      expectClose(loaded.stats['totalTimeS']!.toDouble(), 20.0, 1e-6,
          'paused time survives');
    } finally {
      await dir.delete(recursive: true);
    }
    return true;
  });

  await t('store: empty store and missing file handling', () async {
    final dir = await Directory.systemTemp.createTemp('ridestore_empty');
    try {
      final store = RideStore(dir.path);
      expectEq(store.list().length, 0);
      var threw = false;
      try {
        await store.load('does-not-exist');
      } on PathNotFoundException {
        threw = true;
      } on FileSystemException {
        threw = true;
      }
      expectTrue(threw, 'load of missing id throws');
      store.delete('does-not-exist'); // no-op, must not throw
      return true;
    } finally {
      await dir.delete(recursive: true);
    }
  });

  // ---- end-to-end recorder -> export -> store ----
  await t('end-to-end: record with sensors -> GPX/TCX/FIT -> store', () async {
    var nowMs = _t0ms;
    final rec = RideRecorder(
        clock: () => DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true));
    rec.start();
    final noise = Noise(3);
    for (var i = 0; i <= 60; i++) {
      final t = atS(i.toDouble());
      nowMs = _t0ms + i * 1000;
      rec.addSensor(SensorKind.heartRate, 130 + i * 0.5);
      rec.addSensor(SensorKind.cadence, 85 + (i % 4));
      rec.addSensor(SensorKind.power, 190.0 + i);
      rec.addSensor(SensorKind.barometricElevation, 100 + i * 0.5);
      rec.addGps(t, 52.0 + i * 8.0 / 111320.0 + noise.gauss() * 3 / 111320.0,
          13.0 + noise.gauss() * 3 / (111320.0 * 0.6157),
          accuracy: 4);
    }
    nowMs += 1000;
    final ride = rec.stop();
    expectEq(ride.points.length, 61);
    // all exports parse
    final gpx = parseXml(toGpx(ride));
    expectEq(gpx.root.find('trk')!.find('trkseg')!.findAll('trkpt').length, 61);
    final tcx = parseXml(toTcx(ride));
    expectEq(
        tcx.root
            .find('Activities')!
            .find('Activity')!
            .find('Lap')!
            .find('Track')!
            .findAll('Trackpoint')
            .length,
        61);
    final fit = parseFit(toFit(ride));
    expectEq(fit.ofType(20).length, 61);
    expectTrue(ride.points.every((p) => p.hr != null && p.power != null && p.ele != null),
        'sensors attached to every point');
    // store round trip
    final dir = await Directory.systemTemp.createTemp('ridestore_e2e');
    try {
      final store = RideStore(dir.path);
      await store.save(ride);
      final loaded = await store.load(ride.id);
      expectEq(loaded.points.length, 61);
      expectClose(loaded.stats['distanceM']!.toDouble(),
          ride.stats['distanceM']!.toDouble(), 1e-9);
    } finally {
      await dir.delete(recursive: true);
    }
    return true;
  });

  // ---------------------------------------------------------------- summary
  stdout.writeln('');
  stdout.writeln('PASS: $_pass  FAIL: $_fail');
  if (_fail > 0) {
    stdout.writeln('Failures:');
    for (final f in _failures) {
      stdout.writeln('  - $f');
    }
    exit(1);
  }
}
