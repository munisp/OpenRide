/// RecordingController — owns a RideRecorder session for the app lifetime so
/// recording survives tab switches (SPEC §7 Record screen). Feeds GPS fixes,
/// BLE sensor samples and barometric elevation into ride_core.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ride_core/ride_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../platform/barometer_adapter.dart';
import '../platform/ble_sensor_adapter.dart';
import '../platform/foreground_service.dart';
import '../platform/location_adapter.dart';

class RecordingController extends ChangeNotifier {
  final LocationAdapter location;
  final BleSensorAdapter ble;
  final BarometerAdapter baro;
  final RideStore store;

  RecordingController({
    required this.location,
    required this.ble,
    required this.baro,
    required this.store,
  }) {
    _recorder = RideRecorder(onPoint: (_, __) => notifyListeners());
  }

  late final RideRecorder _recorder;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _ticker;
  DateTime? _startedAt;

  /// Latest live values for the stats grid.
  final Map<SensorKind, double> liveSensor = {};
  LocationFix? lastFix;
  Ride? lastCompletedRide;

  RecorderState get state => _recorder.state;
  RideRecorder get recorder => _recorder;
  bool get isActive => state != RecorderState.idle;
  int get pointCount => _recorder.pointCount;
  int get rejectedFixes => _recorder.rejectedFixes;

  /// Wall-clock duration of the session minus accumulated pause time.
  Duration get elapsed {
    final start = _startedAt;
    if (start == null) return Duration.zero;
    var d = DateTime.now().toUtc().difference(start) - _recorder.pausedTotal;
    if (state == RecorderState.paused && _pauseBegan != null) {
      d -= DateTime.now().toUtc().difference(_pauseBegan!);
    }
    return d.isNegative ? Duration.zero : d;
  }

  DateTime? _pauseBegan;

  /// Live distance/speed stats, recomputed from recorded points.
  Map<String, num> get liveStats =>
      computeRideStats(_recorder.points, pausedTotal: _recorder.pausedTotal);

  Future<bool> start() async {
    if (state != RecorderState.idle) return false;
    final perm = await location.ensurePermission();
    if (perm != LocationPermissionState.granted) return false;
    // Foreground-service notification permission (Android 13+).
    await Permission.notification.request();

    _recorder.start();
    _startedAt = DateTime.now().toUtc();
    liveSensor.clear();
    lastCompletedRide = null;
    _pauseBegan = null;

    _subs.add(location.fixes().listen(_onFix, onError: (Object _) {}));
    _subs.add(ble.samples.listen(_onSensor, onError: (Object _) {}));
    _subs.add(baro.elevationM().listen((ele) {
      liveSensor[SensorKind.barometricElevation] = ele;
      if (_recorder.state == RecorderState.recording) {
        _recorder.addSensor(SensorKind.barometricElevation, ele);
      }
    }, onError: (Object _) {
      // device without barometer
    }));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      notifyListeners();
    });

    await WakelockPlus.enable();
    await ForegroundServiceBridge.startRecording();
    notifyListeners();
    return true;
  }

  void _onFix(LocationFix fix) {
    lastFix = fix;
    if (fix.speedMps != null) {
      liveSensor[SensorKind.speed] = fix.speedMps!;
    }
    if (_recorder.state != RecorderState.recording) {
      notifyListeners();
      return;
    }
    try {
      _recorder.addGps(fix.t, fix.lat, fix.lon,
          accuracy: fix.accuracyM, speed: fix.speedMps);
    } on StateError {
      // raced a stop(); ignore
    }
    notifyListeners();
  }

  void _onSensor(SensorSample s) {
    liveSensor[s.kind] = s.value;
    _recorder.addSensor(s.kind, s.value); // no-op while idle
    notifyListeners();
  }

  void pause() {
    if (state != RecorderState.recording) return;
    _pauseBegan = DateTime.now().toUtc();
    _recorder.pause();
    notifyListeners();
  }

  void resume() {
    if (state != RecorderState.paused) return;
    _recorder.resume();
    _pauseBegan = null;
    notifyListeners();
  }

  /// Stops, persists the ride and returns it (null when nothing recorded).
  Future<Ride?> stop() async {
    if (state == RecorderState.idle) return null;
    final ride = _recorder.stop();
    await _shutdownStreams();
    _pauseBegan = null;
    lastCompletedRide = ride;
    if (ride.points.isNotEmpty) {
      await store.save(ride);
    }
    notifyListeners();
    return ride;
  }

  Future<void> _shutdownStreams() async {
    _ticker?.cancel();
    _ticker = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await ForegroundServiceBridge.stop();
    // Only release the wakelock when navigation isn't holding it too; the
    // navigation controller re-enables it on start and disables on stop.
    await WakelockPlus.disable();
  }

  /// Current speed shown in the grid: GPS speed, else last BLE speed.
  double? get currentSpeedMps =>
      lastFix?.speedMps ?? liveSensor[SensorKind.speed];
}
