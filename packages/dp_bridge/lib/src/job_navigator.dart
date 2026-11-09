/// Contract C1 runtime — per-job navigation session.
///
/// Wraps RouterEngine (routing), nav_engine.Navigator (turn-by-turn) and
/// ride_core.RideRecorder (track recording) into one job-scoped session:
/// [startJob] routes current-position/pickup → stops… → dropoff, [update]
/// feeds GPS fixes to both navigation and recording and returns a [NavEvent]
/// (the JSON payload a host app polls/receives), [finishJob] stops recording
/// and builds the Contract C2 [TrackSummary] ready for upload.
library;

import 'package:nav_engine/nav_engine.dart';
import 'package:ride_core/ride_core.dart';

import 'job_payload.dart';
import 'track_summary.dart';

/// Navigation state snapshot delivered to the host app after each GPS fix.
class NavEvent {
  final double distToNextManeuverM;

  /// Human-readable instruction for the next maneuver (null when none).
  final String? instruction;

  /// True when the cross-track distance exceeds the off-route threshold.
  final bool offRoute;

  /// True while a reroute attempt is in progress/just attempted.
  final bool rerouting;
  final double etaS;
  final double remainingM;

  const NavEvent({
    required this.distToNextManeuverM,
    required this.instruction,
    required this.offRoute,
    required this.rerouting,
    required this.etaS,
    required this.remainingM,
  });

  factory NavEvent.fromNavState(NavState s) => NavEvent(
        distToNextManeuverM: s.distToNextManeuverM,
        instruction: s.next?.instruction,
        offRoute: s.offRouteDistM > Navigator.offRouteThresholdM,
        rerouting: s.rerouting,
        etaS: s.etaS,
        remainingM: s.remainingM,
      );

  Map<String, Object?> toJson() => {
        'distToNextManeuverM': distToNextManeuverM,
        'instruction': instruction,
        'offRoute': offRoute,
        'rerouting': rerouting,
        'etaS': etaS,
        'remainingM': remainingM,
      };

  @override
  String toString() =>
      'NavEvent(${distToNextManeuverM.toStringAsFixed(0)}m to "${instruction ?? '-'}", '
      'remaining ${remainingM.toStringAsFixed(0)}m, offRoute=$offRoute, rerouting=$rerouting)';
}

/// A job currently being navigated.
class ActiveJob {
  final JobPayload payload;
  final RouteResult route;
  final Navigator navigator;

  const ActiveJob(this.payload, this.route, this.navigator);
}

class JobNavigator {
  final RouterEngine engine;

  /// Bundle directory backing the loaded graph (when opened via [open]).
  final String? bundleDir;
  final DateTime Function() _clock;
  final RideRecorder Function() _recorderFactory;

  ActiveJob? _active;
  RideRecorder? _recorder;

  factory JobNavigator(
    RouterEngine engine, {
    DateTime Function()? clock,
    RideRecorder Function()? recorderFactory,
  }) {
    final c = clock ?? (() => DateTime.now().toUtc());
    return JobNavigator._(engine, null, c,
        recorderFactory ?? (() => RideRecorder(clock: c)));
  }

  /// Creates a RouterEngine, loads the graph from [bundleDir] (the job's
  /// offline city bundle) and returns a ready JobNavigator.
  static Future<JobNavigator> open(
    String bundleDir, {
    DateTime Function()? clock,
    RideRecorder Function()? recorderFactory,
  }) async {
    final engine = createRouterEngine();
    await engine.loadGraph(bundleDir);
    final c = clock ?? (() => DateTime.now().toUtc());
    return JobNavigator._(engine, bundleDir, c,
        recorderFactory ?? (() => RideRecorder(clock: c)));
  }

  JobNavigator._(this.engine, this.bundleDir, this._clock, this._recorderFactory);

  ActiveJob? get activeJob => _active;

  /// Routes the job and starts navigation + recording.
  ///
  /// The route starts at [currentPosition] when given (typical: driver is
  /// already en route), otherwise at the job's pickup. The engine must have a
  /// graph loaded. Throws [StateError] when a job is already active; routing
  /// failures propagate (e.g. [NoRouteException]) and leave no job active.
  RouteResult startJob(JobPayload job, {GeoPoint? currentPosition}) {
    if (_active != null) {
      throw StateError('job ${_active!.payload.jobId} is already active');
    }
    final route = engine.route(RouteRequest(
      from: currentPosition ?? job.pickup.point,
      to: job.dropoff.point,
      via: [for (final s in job.stops) s.point],
      profile: job.profile,
      elevationFromSrtm: false,
    ));
    final nav = Navigator(route, engine, job.profile, clock: _clock);
    final recorder = _recorderFactory()..start();
    _active = ActiveJob(job, route, nav);
    _recorder = recorder;
    return route;
  }

  /// Feeds one GPS fix: recorded (Kalman-filtered) and used for navigation
  /// state (maneuvers, off-route detection, ETA). Returns the [NavEvent]
  /// snapshot the host app consumes.
  NavEvent update(
    GeoPoint pos, {
    double speedMps = 0.0,
    double headingDeg = 0.0,
    double? accuracyM,
  }) {
    final active = _active;
    final recorder = _recorder;
    if (active == null || recorder == null) {
      throw StateError('no active job — call startJob first');
    }
    recorder.addGps(_clock(), pos.lat, pos.lon,
        accuracy: accuracyM, speed: speedMps);
    return NavEvent.fromNavState(active.navigator.update(pos, speedMps, headingDeg));
  }

  /// Pauses recording (e.g. waiting at a pickup); navigation keeps running.
  void pauseRecording() => _requireRecorder().pause();

  void resumeRecording() => _requireRecorder().resume();

  /// Stops recording and returns the Contract C2 summary for the job.
  /// Clears the active job so [startJob] can be called again.
  TrackSummary finishJob({required String deviceId}) {
    final active = _active;
    final recorder = _recorder;
    if (active == null || recorder == null) {
      throw StateError('no active job — call startJob first');
    }
    final ride = recorder.stop();
    _active = null;
    _recorder = null;
    return TrackSummary.fromRide(
      ride: ride,
      jobId: active.payload.jobId,
      deviceId: deviceId,
    );
  }

  /// Abandons the active job without producing a summary.
  void cancelJob() {
    final recorder = _recorder;
    if (recorder != null && recorder.state != RecorderState.idle) {
      recorder.stop(); // discarded
    }
    _active = null;
    _recorder = null;
  }

  RideRecorder _requireRecorder() {
    final r = _recorder;
    if (_active == null || r == null) {
      throw StateError('no active job — call startJob first');
    }
    return r;
  }
}
