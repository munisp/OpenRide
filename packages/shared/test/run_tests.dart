// Zero-dependency test harness for packages/shared (SPEC §8).
import 'dart:io';
import 'dart:math' as math;

import '../lib/shared.dart';

int _passed = 0;
int _failed = 0;

void t(String name, bool Function() f) {
  try {
    if (f()) {
      _passed++;
      stdout.writeln('PASS $name');
    } else {
      _failed++;
      stdout.writeln('FAIL $name');
    }
  } catch (e, st) {
    _failed++;
    stdout.writeln('FAIL $name: $e\n$st');
  }
}

void expectEq(Object? a, Object? b) {
  if (a != b) throw StateError('expected $b, got $a');
}

void expectClose(double a, double b, double tol) {
  if ((a - b).abs() > tol) throw StateError('expected $b ± $tol, got $a');
}

void main() {
  // --- haversine vs known city pairs -------------------------------------
  t('haversine Berlin->Munich ~504km', () {
    const berlin = GeoPoint(52.52, 13.405);
    const munich = GeoPoint(48.137, 11.575);
    final d = berlin.distanceTo(munich);
    return (d - 504000).abs() < 6000; // known ~504 km
  });
  t('haversine London->Paris ~344km', () {
    const london = GeoPoint(51.5074, -0.1278);
    const paris = GeoPoint(48.8566, 2.3522);
    final d = london.distanceTo(paris);
    return (d - 344000).abs() < 5000;
  });
  t('haversine zero distance', () {
    const p = GeoPoint(10, 20);
    return p.distanceTo(p) == 0;
  });
  t('haversine antipodal ~ half circumference', () {
    const a = GeoPoint(0, 0);
    const b = GeoPoint(0, 180);
    final d = a.distanceTo(b);
    return (d - math.pi * GeoPoint.earthRadiusM).abs() < 1000;
  });

  // --- bearing ------------------------------------------------------------
  t('bearing due north', () {
    const a = GeoPoint(50.0, 8.0);
    const b = GeoPoint(51.0, 8.0);
    expectClose(a.bearingTo(b), 0, 0.01);
    return true;
  });
  t('bearing due east', () {
    const a = GeoPoint(50.0, 8.0);
    const b = GeoPoint(50.0, 9.0);
    expectClose(a.bearingTo(b), 90, 0.5);
    return true;
  });
  t('bearing due south', () {
    const a = GeoPoint(51.0, 8.0);
    const b = GeoPoint(50.0, 8.0);
    expectClose(a.bearingTo(b), 180, 0.01);
    return true;
  });

  // --- destination round trip ---------------------------------------------
  t('destination round trip', () {
    const a = GeoPoint(52.5, 13.4);
    final b = a.destination(73.0, 5000.0);
    expectClose(a.distanceTo(b), 5000.0, 0.5);
    expectClose(a.bearingTo(b), 73.0, 0.5);
    return true;
  });
  t('destination due east stays on parallel', () {
    const a = GeoPoint(48.0, 11.0);
    final b = a.destination(90.0, 10000.0);
    expectClose(b.lat, 48.0, 0.005);
    return b.lon > 11.0;
  });

  // --- GeoBounds ----------------------------------------------------------
  t('GeoBounds contains/center/expand', () {
    const b = GeoBounds(48.0, 11.0, 49.0, 12.0);
    if (!b.contains(const GeoPoint(48.5, 11.5))) return false;
    if (b.contains(const GeoPoint(49.5, 11.5))) return false;
    final c = b.center();
    expectClose(c.lat, 48.5, 1e-12);
    expectClose(c.lon, 11.5, 1e-12);
    final e = b.expand(const GeoPoint(47.0, 13.0));
    expectClose(e.minLat, 47.0, 1e-12);
    expectClose(e.maxLon, 13.0, 1e-12);
    // original unchanged
    expectClose(b.minLat, 48.0, 1e-12);
    return true;
  });
  t('GeoBounds.of', () {
    final b = GeoBounds.of(
        [const GeoPoint(1, 2), const GeoPoint(-3, 5), const GeoPoint(4, -1)]);
    expectClose(b.minLat, -3, 1e-12);
    expectClose(b.maxLat, 4, 1e-12);
    expectClose(b.minLon, -1, 1e-12);
    expectClose(b.maxLon, 5, 1e-12);
    return true;
  });

  // --- polyline6 round trip -----------------------------------------------
  t('polyline6 round trip', () {
    final pts = [
      const GeoPoint(52.530000, 13.405000),
      const GeoPoint(52.530012, 13.405500),
      const GeoPoint(52.529999, 13.406010),
      const GeoPoint(52.499999, 13.500000),
      const GeoPoint(48.137154, 11.576124),
    ];
    final enc = encodePolyline6(pts);
    final dec = decodePolyline6(enc);
    expectEq(dec.length, pts.length);
    for (var i = 0; i < pts.length; i++) {
      expectClose(dec[i].lat, pts[i].lat, 1e-6);
      expectClose(dec[i].lon, pts[i].lon, 1e-6);
    }
    return true;
  });
  t('polyline6 known vector (precision5 example scaled)', () {
    // The canonical Google example points at precision 6:
    final pts = [
      const GeoPoint(38.5, -120.2),
      const GeoPoint(40.7, -120.95),
      const GeoPoint(43.252, -126.453),
    ];
    final enc = encodePolyline6(pts);
    final dec = decodePolyline6(enc);
    expectEq(dec.length, 3);
    for (var i = 0; i < 3; i++) {
      expectClose(dec[i].lat, pts[i].lat, 1e-6);
      expectClose(dec[i].lon, pts[i].lon, 1e-6);
    }
    return true;
  });
  t('polyline6 empty', () {
    expectEq(encodePolyline6(const []), '');
    expectEq(decodePolyline6('').length, 0);
    return true;
  });

  // --- path helpers --------------------------------------------------------
  t('pathLengthM', () {
    final pts = [
      const GeoPoint(50.0, 8.0),
      const GeoPoint(50.0, 9.0),
      const GeoPoint(50.0, 10.0),
    ];
    final total = pathLengthM(pts);
    final seg = pts[0].distanceTo(pts[1]);
    expectClose(total, 2 * seg, 0.001);
    return true;
  });
  t('cumulativeDistancesM', () {
    final pts = [
      const GeoPoint(50.0, 8.0),
      const GeoPoint(50.0, 9.0),
      const GeoPoint(51.0, 9.0),
    ];
    final cum = cumulativeDistancesM(pts);
    expectEq(cum.length, 3);
    expectClose(cum[0], 0, 1e-12);
    expectClose(cum[1], pts[0].distanceTo(pts[1]), 1e-9);
    expectClose(cum[2], pathLengthM(pts), 1e-9);
    return true;
  });

  // --- signedTurnAngle ------------------------------------------------------
  t('turn angle right', () {
    // going north then east => +90 right turn
    const a = GeoPoint(50.0, 8.0);
    const b = GeoPoint(51.0, 8.0);
    const c = GeoPoint(51.0, 9.0);
    expectClose(signedTurnAngle(a, b, c), 90, 0.5);
    return true;
  });
  t('turn angle left', () {
    // going north then west => -90 left turn
    const a = GeoPoint(50.0, 8.0);
    const b = GeoPoint(51.0, 8.0);
    const c = GeoPoint(51.0, 7.0);
    expectClose(signedTurnAngle(a, b, c), -90, 0.5);
    return true;
  });
  t('turn angle straight ~0', () {
    const a = GeoPoint(50.0, 8.0);
    const b = GeoPoint(50.5, 8.0);
    const c = GeoPoint(51.0, 8.0);
    expectClose(signedTurnAngle(a, b, c), 0, 0.01);
    return true;
  });
  t('turn angle u-turn ~180', () {
    const a = GeoPoint(50.0, 8.0);
    const b = GeoPoint(50.5, 8.0);
    const c = GeoPoint(50.0, 8.0);
    expectClose(signedTurnAngle(a, b, c).abs(), 180, 0.01);
    return true;
  });

  stdout.writeln('---');
  stdout.writeln('shared: $_passed passed, $_failed failed');
  if (_failed > 0) exit(1);
}
