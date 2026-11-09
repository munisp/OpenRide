/// Contract C1 runtime — per-job navigation session.
///
/// Wraps RouterEngine (routing), nav_engine.Navigator (turn-by-turn) and
/// ride_core.RideRecorder (track recording) into one job-scoped session:
/// [startJob] routes pickup → stops… → dropoff, [update] feeds GPS fixes to
/// both navigation and recording, [finishJob] stops recording and builds the
/// Contract C2 [TrackSummary] ready for upload.
library;

import 'package:nav_engine/nav_engine.dart';
import 'package:ride_core/ride_core.dart';

import 'job_payload.dart';
import 'track_summary.dart';

/// A job currently being navigated.
class ActiveJob {
  final JobPayload payload;
  final RouteResult route;
  final Navigator navigator;

  const ActiveJob(this.payload, this.route, this.navigator);
}

class JobNavigator {
  final RouterEngine engine;
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
    return JobNavigator._(engine, c, recorderFactory ?? (() => RideRecorder(clock: c)));
  }

  JobNavigator._(this.engine, this._clock, this._recorderFactory);

  ActiveJob? get activeJob => _active;

  /// Routes the job and starts navigation + recording.
  ///
  /// The engine must already have a graph loaded (`loadGraph`). Throws
  /// [StateError] when a job is already active; routing failures propagate
  /// (e.g. [NoRouteException]) and leave no job active.
  RouteResult startJob(JobPayload job) {
    if (_active != null) {
      throw StateError('job ${_active!.payload.jobId} is already active');
    }
    final route = engine.route(RouteRequest(
      from: job.pickup.point,
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
  /// state (maneuvers, off-route detection, ETA).
  NavState update(
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
    return active.navigator.update(pos, speedMps, headingDeg);
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
