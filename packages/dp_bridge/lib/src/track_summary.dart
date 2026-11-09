/// Contract C2 — track summary (`openride.track.v1`).
///
/// Built from a completed ride_core [Ride]; uploaded to DeliveryPlatform's
/// `openrideTelemetry.ingestTrack` endpoint (see [UploadQueue]).
library;

import 'dart:convert';

import 'package:ride_core/ride_core.dart';
import 'package:shared/shared.dart';

/// A compact, uploadable summary of one completed job track.
class TrackSummary {
  static const String schema = 'openride.track.v1';

  final String jobId;
  final String deviceId;
  final DateTime startedAt;
  final DateTime endedAt;
  final int distanceM;
  final int movingTimeS;
  final int totalTimeS;
  final double maxSpeedMps;
  final double ascentM;
  final double descentM;

  /// OSRM-style polyline (precision 6) over all recorded track points.
  final String polyline6;

  /// Epoch seconds of the first track point (0 when no points).
  final int epoch0;

  /// Per-point epoch-second deltas relative to [epoch0] (dtS[0] == 0).
  final List<int> dtS;

  final int pointCount;

  const TrackSummary({
    required this.jobId,
    required this.deviceId,
    required this.startedAt,
    required this.endedAt,
    required this.distanceM,
    required this.movingTimeS,
    required this.totalTimeS,
    required this.maxSpeedMps,
    required this.ascentM,
    required this.descentM,
    required this.polyline6,
    required this.epoch0,
    required this.dtS,
    required this.pointCount,
  });

  /// Builds a summary from a finished [Ride] (from `RideRecorder.stop()`).
  factory TrackSummary.fromRide({
    required Ride ride,
    required String jobId,
    required String deviceId,
  }) {
    if (jobId.isEmpty) throw ArgumentError('jobId must not be empty');
    if (deviceId.isEmpty) throw ArgumentError('deviceId must not be empty');
    final pts = ride.points;
    final stats = ride.stats;
    final startedAt = ride.started.toUtc();
    final endedAt = pts.isNotEmpty ? pts.last.t.toUtc() : startedAt;
    final epoch0 = pts.isNotEmpty ? _epochS(pts.first.t) : _epochS(startedAt);
    final dtS = [for (final p in pts) _epochS(p.t) - epoch0];
    return TrackSummary(
      jobId: jobId,
      deviceId: deviceId,
      startedAt: startedAt,
      endedAt: endedAt,
      distanceM: _stat(stats, 'distanceM').round(),
      movingTimeS: _stat(stats, 'movingTimeS').round(),
      totalTimeS: _stat(stats, 'totalTimeS').round(),
      maxSpeedMps: _stat(stats, 'maxSpeedMps'),
      ascentM: _stat(stats, 'elevationGainM'),
      descentM: _stat(stats, 'elevationLossM'),
      polyline6: encodePolyline6([for (final p in pts) GeoPoint(p.lat, p.lon)]),
      epoch0: epoch0,
      dtS: dtS,
      pointCount: pts.length,
    );
  }

  static int _epochS(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ 1000;

  static double _stat(Map<String, num> stats, String key) =>
      (stats[key] ?? 0).toDouble();

  /// Decoded track points (lat/lon only); handy for tests and debugging.
  List<GeoPoint> get points => decodePolyline6(polyline6);

  Map<String, Object?> toJson() => {
        'schema': schema,
        'jobId': jobId,
        'deviceId': deviceId,
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
        'distanceM': distanceM,
        'movingTimeS': movingTimeS,
        'totalTimeS': totalTimeS,
        'maxSpeedMps': maxSpeedMps,
        'ascentM': ascentM,
        'descentM': descentM,
        'polyline6': polyline6,
        'epoch0': epoch0,
        'dtS': dtS,
        'pointCount': pointCount,
      };

  String toJsonString() => jsonEncode(toJson());

  @override
  String toString() =>
      'TrackSummary($jobId, $pointCount pts, ${distanceM} m, ${totalTimeS} s)';
}
