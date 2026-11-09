/// RideRecorder — idle/recording/paused state machine (SPEC §6).
///
/// GPS fixes pass through a constant-velocity Kalman filter with an
/// innovation gate; fixes while paused are ignored so paused intervals
/// contribute neither time nor distance. Sensor samples (BLE-style, no
/// timestamp in the API) are stamped with the recorder clock and attached
/// to track points by linear interpolation (nearest-sample hold when the
/// channel has no bracketing pair yet).
library;

import 'kalman.dart';
import 'model.dart';

enum RecorderState { idle, recording, paused }

enum SensorKind { heartRate, cadence, speed, power, temperature, barometricElevation }

/// How long (seconds) a sensor sample stays eligible for nearest-attach when
/// no bracketing interpolation pair exists.
const double kSensorStalenessS = 10.0;

class RideRecorder {
  final DateTime Function() _clock;
  final GpsKalmanFilter kalman;
  final void Function(String rideId, TrackPoint point)? onPoint;

  RecorderState _state = RecorderState.idle;
  String? _id;
  DateTime? _started;
  final List<TrackPoint> _points = [];
  final Map<SensorKind, List<_Sample>> _channels = {};
  Duration _pausedTotal = Duration.zero;
  DateTime? _pauseStarted;
  final List<PauseWindow> _pauses = [];
  int _rejectedFixes = 0;
  static int _idCounter = 0;

  RideRecorder({DateTime Function()? clock, GpsKalmanFilter? kalman, this.onPoint})
      : _clock = clock ?? (() => DateTime.now().toUtc()),
        kalman = kalman ?? GpsKalmanFilter();

  RecorderState get state => _state;
  int get pointCount => _points.length;
  int get rejectedFixes => _rejectedFixes;
  Duration get pausedTotal => _pausedTotal;
  List<TrackPoint> get points => List.unmodifiable(_points);

  void start() {
    if (_state != RecorderState.idle) {
      throw StateError('cannot start from $_state');
    }
    _state = RecorderState.recording;
    _points.clear();
    _channels.clear();
    _pausedTotal = Duration.zero;
    _pauseStarted = null;
    _pauses.clear();
    _rejectedFixes = 0;
    kalman.reset();
    _started = _clock();
    _id = 'ride-${_started!.millisecondsSinceEpoch}-${_idCounter++}';
  }

  void pause() {
    if (_state != RecorderState.recording) {
      throw StateError('cannot pause from $_state');
    }
    _state = RecorderState.paused;
    _pauseStarted = _clock();
  }

  void resume() {
    if (_state != RecorderState.paused) {
      throw StateError('cannot resume from $_state');
    }
    final now = _clock();
    _pausedTotal += now.difference(_pauseStarted!);
    _pauses.add((start: _pauseStarted!, end: now));
    _pauseStarted = null;
    _state = RecorderState.recording;
    kalman.reset(); // do not bridge the pause gap through the filter
  }

  /// Stops recording and returns the completed [Ride] with stats.
  /// Paused wall-clock time is excluded from the stats' total time.
  Ride stop() {
    if (_state == RecorderState.idle) {
      throw StateError('cannot stop from idle');
    }
    if (_state == RecorderState.paused) {
      final now = _clock();
      _pausedTotal += now.difference(_pauseStarted!);
      _pauses.add((start: _pauseStarted!, end: now));
      _pauseStarted = null;
    }
    _state = RecorderState.idle;
    final pts = List<TrackPoint>.from(_points);
    final stats =
        computeRideStats(pts, pausedTotal: _pausedTotal, pauses: _pauses);
    return Ride(
        id: _id!,
        started: _started!,
        points: pts,
        stats: stats,
        pauses: List.unmodifiable(_pauses));
  }

  /// Feed a GPS fix. While paused the fix is discarded (paused intervals
  /// are excluded from time and distance). While idle this is a no-op-safe
  /// StateError to surface integration bugs.
  void addGps(DateTime t, double lat, double lon, {double? accuracy, double? speed}) {
    switch (_state) {
      case RecorderState.idle:
        throw StateError('addGps while idle');
      case RecorderState.paused:
        return; // excluded
      case RecorderState.recording:
        break;
    }
    final utc = t.toUtc();
    final r = kalman.update(utc, lat, lon, accuracy: accuracy, speedMps: speed);
    if (!r.accepted) {
      _rejectedFixes++;
      return;
    }
    final sensorSpeed = _channelValue(SensorKind.speed, utc);
    final spd = sensorSpeed ?? speed ?? r.speedMps;
    final tp = TrackPoint(utc, r.lat, r.lon,
        ele: _channelValue(SensorKind.barometricElevation, utc),
        speed: spd,
        hr: _channelValue(SensorKind.heartRate, utc),
        cad: _channelValue(SensorKind.cadence, utc),
        power: _channelValue(SensorKind.power, utc),
        temp: _channelValue(SensorKind.temperature, utc));
    _points.add(tp);
    onPoint?.call(_id!, tp);
  }

  /// Feed a sensor sample; timestamped with the recorder clock.
  /// No-op while idle.
  void addSensor(SensorKind k, double v) {
    if (_state == RecorderState.idle) return;
    final list = _channels.putIfAbsent(k, () => []);
    list.add(_Sample(_clock(), v));
  }

  /// For tests/deterministic integrations: feed a sensor sample with an
  /// explicit timestamp (same storage/interpolation path as [addSensor]).
  void addSensorAt(SensorKind k, double v, DateTime t) {
    if (_state == RecorderState.idle) return;
    _channels.putIfAbsent(k, () => []).add(_Sample(t.toUtc(), v));
  }

  /// Linear interpolation between bracketing samples; nearest-sample hold
  /// when only one side exists and it is fresh enough.
  double? _channelValue(SensorKind k, DateTime t) {
    final ch = _channels[k];
    if (ch == null || ch.isEmpty) return null;
    _Sample? before, after;
    for (final s in ch) {
      if (!s.t.isAfter(t)) {
        before = s;
      } else {
        after = s;
        break;
      }
    }
    if (before != null && after != null) {
      final spanMs = after.t.difference(before.t).inMilliseconds;
      if (spanMs <= 0) return after.v;
      final f = t.difference(before.t).inMilliseconds / spanMs;
      return before.v + (after.v - before.v) * f;
    }
    final s = before ?? after!;
    final ageS = (t.difference(s.t).inMilliseconds).abs() / 1000.0;
    return ageS <= kSensorStalenessS ? s.v : null;
  }
}

class _Sample {
  final DateTime t;
  final double v;
  _Sample(this.t, this.v);
}
