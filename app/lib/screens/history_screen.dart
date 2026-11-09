/// History screen (SPEC §7): RideStore list, detail view with stats + track
/// sparkline painter, GPX/TCX/FIT export via share_plus, delete.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ride_core/ride_core.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../widgets/format.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  int _reloadToken = 0;

  AppState get _app => AppState.instance;

  @override
  Widget build(BuildContext context) {
    // RideStore.list() is a cheap sync catalog read; _reloadToken forces a
    // rebuild after save/delete.
    final rides = _app.rideStore.list();
    return Scaffold(
      key: ValueKey(_reloadToken),
      appBar: AppBar(title: const Text('History')),
      body: rides.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No rides yet.\nRecord one on the Record tab.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: rides.length,
              itemBuilder: (ctx, i) {
                final r = rides[i];
                return Dismissible(
                  key: ValueKey(r.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: const Icon(Icons.delete),
                  ),
                  confirmDismiss: (_) => _confirmDelete(r),
                  onDismissed: (_) {
                    _app.rideStore.delete(r.id);
                    setState(() => _reloadToken++);
                  },
                  child: ListTile(
                    leading: const Icon(Icons.pedal_bike),
                    title: Text(fmtDistance(r.distanceM)),
                    subtitle: Text(
                        '${_fmtDate(r.started)} · ${fmtDuration(r.totalTimeS)} · '
                        '${r.pointCount} pts'
                        '${r.calories > 0 ? ' · ${r.calories.round()} kcal' : ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final ride = await _app.rideStore.load(r.id);
                      if (!mounted) return;
                      final changed = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => RideDetailScreen(ride: ride),
                        ),
                      );
                      if (changed == true) {
                        setState(() => _reloadToken++);
                      }
                    },
                  ),
                );
              },
            ),
    );
  }

  Future<bool> _confirmDelete(RideSummary r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete ride?'),
        content: Text(
            '${fmtDistance(r.distanceM)} from ${_fmtDate(r.started)} will be permanently deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    return ok ?? false;
  }

  static String _fmtDate(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')} '
        '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

class RideDetailScreen extends StatelessWidget {
  final Ride ride;

  const RideDetailScreen({super.key, required this.ride});

  AppState get _app => AppState.instance;

  @override
  Widget build(BuildContext context) {
    final s = ride.stats;
    num stat(String k) => s[k] ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(_HistoryScreenState._fmtDate(ride.started)),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete ride',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete ride?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true && context.mounted) {
                _app.rideStore.delete(ride.id);
                Navigator.of(context).pop(true);
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: SizedBox(
              height: 180,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _TrackSparklinePainter(ride.points,
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _statsGrid(context, stat),
          const SizedBox(height: 12),
          Text('Export', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              for (final (label, ext) in const [
                ('GPX', 'gpx'),
                ('TCX', 'tcx'),
                ('FIT', 'fit'),
              ])
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: OutlinedButton(
                      onPressed: () => _export(context, ext),
                      child: Text(label),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statsGrid(BuildContext context, num Function(String) stat) {
    final rows = <(String, String)>[
      ('Distance', fmtDistance(stat('distanceM').toDouble())),
      ('Total time', fmtDuration(stat('totalTimeS').toDouble())),
      ('Moving time', fmtDuration(stat('movingTimeS').toDouble())),
      ('Avg speed', '${fmtSpeed(stat('avgSpeedMps').toDouble())} km/h'),
      ('Avg moving', '${fmtSpeed(stat('avgMovingSpeedMps').toDouble())} km/h'),
      ('Max speed', '${fmtSpeed(stat('maxSpeedMps').toDouble())} km/h'),
      ('Elev. gain', '${stat('elevationGainM').round()} m'),
      ('Elev. loss', '${stat('elevationLossM').round()} m'),
      if (stat('avgHr') > 0) ('Avg HR', '${stat('avgHr').round()} bpm'),
      if (stat('maxHr') > 0) ('Max HR', '${stat('maxHr').round()} bpm'),
      if (stat('avgCadence') > 0)
        ('Avg cadence', '${stat('avgCadence').round()} rpm'),
      if (stat('avgPower') > 0) ('Avg power', '${stat('avgPower').round()} W'),
      if (stat('maxPower') > 0) ('Max power', '${stat('maxPower').round()} W'),
      if (stat('calories') > 0) ('Calories', '${stat('calories').round()} kcal'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(label), Text(value)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _export(BuildContext context, String ext) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await getTemporaryDirectory();
      final safeId = ride.id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
      final path = '${dir.path}/$safeId.$ext';
      final file = File(path);
      switch (ext) {
        case 'gpx':
          await file.writeAsString(toGpx(ride));
        case 'tcx':
          await file.writeAsString(toTcx(ride));
        case 'fit':
          await file.writeAsBytes(toFit(ride), flush: true);
      }
      await Share.shareXFiles(
        [XFile(path, mimeType: _mimeFor(ext))],
        text: 'OpenRide ride ${ride.id} ($ext)',
      );
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  static String _mimeFor(String ext) => switch (ext) {
        'gpx' => 'application/gpx+xml',
        'tcx' => 'application/vnd.garmin.tcx+xml',
        _ => 'application/octet-stream',
      };
}

/// Mini track sparkline: draws the recorded polyline normalized into the
/// canvas, preserving aspect ratio.
class _TrackSparklinePainter extends CustomPainter {
  final List<TrackPoint> points;
  final Color color;

  _TrackSparklinePainter(this.points, {required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) {
      final tp = TextPainter(
        text: const TextSpan(text: 'No track points', style: TextStyle()),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(
          (size.width - tp.width) / 2, (size.height - tp.height) / 2));
      return;
    }
    var minLat = double.infinity, maxLat = -double.infinity;
    var minLon = double.infinity, maxLon = -double.infinity;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }
    final latSpan = math.max(maxLat - minLat, 1e-6);
    final lonSpan = math.max(maxLon - minLon, 1e-6);
    // Correct the aspect ratio for latitude (1 deg lon shrinks with cos).
    final midLat = (minLat + maxLat) / 2;
    final lonScale =
        math.cos(midLat * math.pi / 180).abs().clamp(0.1, 1.0).toDouble();
    final w = lonSpan * lonScale;
    final h = latSpan;
    final scale = math.min(size.width / w, size.height / h) * 0.9;
    final ox = (size.width - w * scale) / 2;
    final oy = (size.height - h * scale) / 2;

    Offset pt(TrackPoint p) => Offset(
          ox + (p.lon - minLon) * lonScale * scale,
          oy + (maxLat - p.lat) * scale,
        );

    final path = Path()..moveTo(pt(points.first).dx, pt(points.first).dy);
    for (var i = 1; i < points.length; i++) {
      path.lineTo(pt(points[i]).dx, pt(points[i]).dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = color);

    // Start (green) / end (red) dots.
    canvas.drawCircle(
        pt(points.first), 4, Paint()..color = const Color(0xFF2E9E44));
    canvas.drawCircle(
        pt(points.last), 4, Paint()..color = const Color(0xFFC62828));
  }

  @override
  bool shouldRepaint(covariant _TrackSparklinePainter old) =>
      old.points != points || old.color != color;
}
