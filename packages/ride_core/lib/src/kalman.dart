/// Constant-velocity 4-state Kalman filter for GPS smoothing (SPEC §6).
///
/// State x = [lat, lon, vLat, vLon] (degrees, degrees/second).
/// Measurement z = [lat, lon] with covariance R derived from the reported
/// GPS accuracy (meters → degrees, longitude scaled by cos(lat)).
/// Measurements whose normalized innovation (Mahalanobis distance²) exceeds
/// the gate are rejected as outliers.
library;

import 'dart:math' as math;

class KalmanResult {
  final double lat, lon, speedMps;
  final bool accepted; // false when the fix was rejected by the gate
  final double innovation2; // Mahalanobis distance squared of this update
  const KalmanResult(this.lat, this.lon, this.speedMps, this.accepted, this.innovation2);
}

class GpsKalmanFilter {
  // meters per degree latitude (WGS-84 mean)
  static const double _mPerDegLat = 111320.0;

  /// Process noise: spectral density of the white acceleration noise (m/s^2).
  final double accelNoise;
  /// Chi-square gate (2 dof). 99% ≈ 9.21; we use 9.21.
  final double gateChi2;
  /// Assumed accuracy (m) when the fix reports none.
  final double defaultAccuracy;

  // state & covariance (4x4 row-major)
  final List<double> _x = List<double>.filled(4, 0.0);
  final List<double> _p = List<double>.filled(16, 0.0);
  DateTime? _t;
  int _consecutiveRejections = 0;

  GpsKalmanFilter({this.accelNoise = 1.5, this.gateChi2 = 9.21, this.defaultAccuracy = 15.0});

  bool get initialized => _t != null;
  int get consecutiveRejections => _consecutiveRejections;

  /// Forget everything (e.g. after a long pause gap).
  void reset() {
    _t = null;
    _consecutiveRejections = 0;
    for (var i = 0; i < 4; i++) {
      _x[i] = 0.0;
    }
    for (var i = 0; i < 16; i++) {
      _p[i] = 0.0;
    }
  }

  double get currentSpeedMps {
    if (!initialized) return 0.0;
    final lat = _x[0];
    final mPerDegLon = _mPerDegLat * math.cos(lat * math.pi / 180.0);
    final vN = _x[2] * _mPerDegLat;
    final vE = _x[3] * mPerDegLon;
    return math.sqrt(vN * vN + vE * vE);
  }

  /// Feed a GPS fix. Returns the filtered estimate.
  KalmanResult update(DateTime t, double lat, double lon,
      {double? accuracy, double? speedMps}) {
    final acc = (accuracy != null && accuracy > 0) ? accuracy : defaultAccuracy;

    if (!initialized) {
      _x[0] = lat;
      _x[1] = lon;
      _x[2] = 0.0;
      _x[3] = 0.0;
      final sLat = acc / _mPerDegLat;
      final mPerDegLon = _mPerDegLat * _cosLat(lat);
      final sLon = acc / mPerDegLon;
      _fillP(sLat * sLat, sLon * sLon);
      _t = t;
      return KalmanResult(lat, lon, speedMps ?? 0.0, true, 0.0);
    }

    var dt = t.difference(_t!).inMilliseconds / 1000.0;
    if (dt < 0) dt = 0; // out-of-order fix: no prediction
    _t = t;

    // ---- Predict ----
    // F = [1 0 dt 0; 0 1 0 dt; 0 0 1 0; 0 0 0 1]
    _x[0] += _x[2] * dt;
    _x[1] += _x[3] * dt;
    // P = F P F' + Q
    _predictP(dt, lat);

    // ---- Measurement ----
    final mPerDegLon = _mPerDegLat * _cosLat(lat);
    final sLat = acc / _mPerDegLat;
    final sLon = acc / mPerDegLon;
    final r00 = sLat * sLat, r11 = sLon * sLon;

    // Innovation y = z - H x  (H = [1 0 0 0; 0 1 0 0])
    final y0 = lat - _x[0];
    final y1 = lon - _x[1];
    // S = H P H' + R
    final s00 = _p[0] + r00;
    final s01 = _p[1];
    final s10 = _p[4];
    final s11 = _p[5] + r11;
    final det = s00 * s11 - s01 * s10;
    if (det <= 0) {
      // degenerate; reinitialize on the measurement
      reset();
      return update(t, lat, lon, accuracy: accuracy, speedMps: speedMps);
    }
    final i00 = s11 / det, i01 = -s01 / det, i10 = -s10 / det, i11 = s00 / det;
    final d2 = y0 * (i00 * y0 + i01 * y1) + y1 * (i10 * y0 + i11 * y1);

    if (d2 > gateChi2) {
      _consecutiveRejections++;
      if (_consecutiveRejections >= 10) {
        // too many rejections: the device probably teleported for real
        // (or the filter diverged) -> reinitialize on this fix.
        reset();
        return update(t, lat, lon, accuracy: accuracy, speedMps: speedMps);
      }
      return KalmanResult(_x[0], _x[1], currentSpeedMps, false, d2);
    }
    _consecutiveRejections = 0;

    // ---- Update: K = P H' S^-1 ; x += K y ; P = (I - K H) P ----
    // P H' = first two columns of P
    final ph = List<List<double>>.generate(4, (r) => [_p[r * 4 + 0], _p[r * 4 + 1]]);
    final k = List<List<double>>.generate(
        4,
        (r) => [
              ph[r][0] * i00 + ph[r][1] * i10,
              ph[r][0] * i01 + ph[r][1] * i11,
            ]);
    for (var r = 0; r < 4; r++) {
      _x[r] += k[r][0] * y0 + k[r][1] * y1;
    }
    final newP = List<double>.filled(16, 0.0);
    for (var r = 0; r < 4; r++) {
      for (var c = 0; c < 4; c++) {
        // (I - K H) P : subtract K[r][:] * P[0..1][c]
        newP[r * 4 + c] = _p[r * 4 + c] - k[r][0] * _p[c] - k[r][1] * _p[4 + c];
      }
    }
    for (var i = 0; i < 16; i++) {
      _p[i] = newP[i];
    }
    _symmetrize();

    return KalmanResult(_x[0], _x[1], currentSpeedMps, true, d2);
  }

  void _fillP(double varLat, double varLon) {
    for (var i = 0; i < 16; i++) {
      _p[i] = 0.0;
    }
    _p[0] = varLat;
    _p[5] = varLon;
    // initial velocity uncertainty: 5 m/s
    final vLat = 5.0 / _mPerDegLat;
    _p[10] = vLat * vLat;
    _p[15] = vLat * vLat;
  }

  /// P = F P F' + Q with F the constant-velocity transition and Q the
  /// discrete white-noise acceleration covariance.
  void _predictP(double dt, double lat) {
    if (dt <= 0) return;
    // F P F': P00 += 2 dt P02 + dt^2 P22 ; P01 += dt(P03 + P12) + dt^2 P23 ; ...
    final p = List<double>.from(_p);
    double g(int r, int c) => p[r * 4 + c];
    // rows/cols 0,1 mix with 2,3
    for (var r = 0; r < 2; r++) {
      for (var c = 0; c < 2; c++) {
        _p[r * 4 + c] = g(r, c) +
            dt * (g(r, c + 2) + g(r + 2, c)) +
            dt * dt * g(r + 2, c + 2);
      }
      for (var c = 2; c < 4; c++) {
        _p[r * 4 + c] = g(r, c) + dt * g(r + 2, c);
        _p[c * 4 + r] = g(c, r) + dt * g(c, r + 2);
      }
    }
    // Q: discrete white noise accel, q converted m/s^2 -> deg/s^2
    final mPerDegLon = _mPerDegLat * _cosLat(lat);
    final qLat = accelNoise / _mPerDegLat;
    final qLon = accelNoise / mPerDegLon;
    final q = [qLat * qLat, qLon * qLon];
    final dt2 = dt * dt, dt3 = dt2 * dt, dt4 = dt3 * dt;
    for (var axis = 0; axis < 2; axis++) {
      final pos = axis, vel = axis + 2;
      final qa = q[axis];
      _p[pos * 4 + pos] += qa * dt4 / 4;
      _p[pos * 4 + vel] += qa * dt3 / 2;
      _p[vel * 4 + pos] += qa * dt3 / 2;
      _p[vel * 4 + vel] += qa * dt2;
    }
    _symmetrize();
  }

  void _symmetrize() {
    for (var r = 0; r < 4; r++) {
      for (var c = r + 1; c < 4; c++) {
        final m = (_p[r * 4 + c] + _p[c * 4 + r]) / 2;
        _p[r * 4 + c] = m;
        _p[c * 4 + r] = m;
      }
    }
  }

  double _cosLat(double lat) {
    final c = math.cos(lat * math.pi / 180.0);
    return c.abs() < 0.01 ? 0.01 : c.abs();
  }
}
