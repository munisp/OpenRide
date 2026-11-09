/// Record screen (SPEC §7): start/pause/resume/stop via RideRecorder, live
/// stats grid, BLE sensor scan/connect sheet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ride_core/ride_core.dart';

import '../app_state.dart';
import '../data/recording_controller.dart';
import '../platform/ble_sensor_adapter.dart';
import '../widgets/format.dart';

class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  AppState get _app => AppState.instance;

  @override
  void initState() {
    super.initState();
    _app.recording.addListener(_onTick);
    _app.ble.addListener(_onTick);
  }

  @override
  void dispose() {
    _app.recording.removeListener(_onTick);
    _app.ble.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rec = _app.recording;
    final stats = rec.isActive ? rec.liveStats : const <String, num>{};
    final distanceM = (stats['distanceM'] ?? 0).toDouble();
    final speed = rec.currentSpeedMps;
    final hr = rec.liveSensor[SensorKind.heartRate];
    final cad = rec.liveSensor[SensorKind.cadence];
    final pwr = rec.liveSensor[SensorKind.power];
    final ele = rec.liveSensor[SensorKind.barometricElevation];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Record'),
        actions: [
          IconButton(
            icon: Badge(
              isLabelVisible: _app.ble.connected.isNotEmpty,
              label: Text('${_app.ble.connected.length}'),
              child: const Icon(Icons.bluetooth),
            ),
            tooltip: 'Sensors',
            onPressed: _showSensorSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              childAspectRatio: 1.9,
              padding: const EdgeInsets.all(12),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                _StatTile(
                    label: 'Speed',
                    value: speed == null ? '—' : fmtSpeed(speed),
                    unit: 'km/h'),
                _StatTile(
                    label: 'Distance',
                    value: (distanceM / 1000).toStringAsFixed(2),
                    unit: 'km'),
                _StatTile(
                    label: 'Time',
                    value: fmtDuration(rec.elapsed.inSeconds.toDouble()),
                    unit: ''),
                _StatTile(
                    label: 'Heart rate',
                    value: hr == null ? '—' : hr.round().toString(),
                    unit: 'bpm'),
                _StatTile(
                    label: 'Cadence',
                    value: cad == null ? '—' : cad.round().toString(),
                    unit: 'rpm'),
                _StatTile(
                    label: 'Power',
                    value: pwr == null ? '—' : pwr.round().toString(),
                    unit: 'W'),
                _StatTile(
                    label: 'Elevation',
                    value: ele == null ? '—' : ele.round().toString(),
                    unit: 'm'),
                _StatTile(
                    label: 'GPS points',
                    value: '${rec.pointCount}',
                    unit: rec.rejectedFixes > 0
                        ? '(${rec.rejectedFixes} filtered)'
                        : ''),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _controls(rec),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(RecordingController rec) {
    switch (rec.state) {
      case RecorderState.idle:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rec.lastCompletedRide != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Saved: ${fmtDistance(rec.lastCompletedRide!.distanceM)} · '
                  '${fmtDuration(rec.lastCompletedRide!.totalTimeS)} — see History',
                  textAlign: TextAlign.center,
                ),
              ),
            FilledButton.icon(
              icon: const Icon(Icons.fiber_manual_record),
              label: const Text('Start recording'),
              style: FilledButton.styleFrom(
                  padding: const EdgeInsets.all(18),
                  backgroundColor: const Color(0xFFC62828)),
              onPressed: () async {
                final ok = await _app.recording.start();
                if (!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text(
                          'Location permission is required to record a ride.')));
                }
              },
            ),
          ],
        );
      case RecorderState.recording:
        return Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.pause),
                label: const Text('Pause'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(18)),
                onPressed: _app.recording.pause,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text('Stop & save'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(18)),
                onPressed: _confirmStop,
              ),
            ),
          ],
        );
      case RecorderState.paused:
        return Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Resume'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(18)),
                onPressed: _app.recording.resume,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.stop),
                label: const Text('Stop & save'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(18)),
                onPressed: _confirmStop,
              ),
            ),
          ],
        );
    }
  }

  Future<void> _confirmStop() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Finish ride?'),
        content:
            const Text('The ride will be saved to your history.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep recording')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Stop & save')),
        ],
      ),
    );
    if (confirm == true) {
      await _app.recording.stop();
    }
  }

  // ------------------------------------------------------------------ sensors

  void _showSensorSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SensorSheet(app: _app),
    ).whenComplete(() {
      // Stop scanning when the sheet closes to save power.
      if (_app.ble.isScanning) _app.ble.stopScan();
    });
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const _StatTile(
      {required this.label, required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(label, style: t.labelMedium),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(TextSpan(children: [
                TextSpan(
                    text: value,
                    style: t.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                if (unit.isNotEmpty)
                  TextSpan(text: ' $unit', style: t.labelMedium),
              ])),
            ),
          ],
        ),
      ),
    );
  }
}

/// BLE scan/connect sheet: discovered devices, connected sensors.
class _SensorSheet extends StatefulWidget {
  final AppState app;
  const _SensorSheet({required this.app});

  @override
  State<_SensorSheet> createState() => _SensorSheetState();
}

class _SensorSheetState extends State<_SensorSheet> {
  List<BleDeviceInfo> _devices = const [];
  String? _error;
  String? _connectingId;
  StreamSubscription<List<BleDeviceInfo>>? _scanSub;

  @override
  void initState() {
    super.initState();
    widget.app.ble.addListener(_onBle);
    _scanSub = widget.app.ble.scanResults.listen((devices) {
      if (mounted) setState(() => _devices = devices);
    });
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    widget.app.ble.removeListener(_onBle);
    super.dispose();
  }

  void _onBle() {
    if (mounted) setState(() {});
  }

  Future<void> _startScan() async {
    setState(() => _error = null);
    try {
      await widget.app.ble.startScan();
    } on StateError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.app.ble;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text('Sensors',
                    style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                if (ble.isScanning)
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: ble.isScanning ? ble.stopScan : _startScan,
                  child: Text(ble.isScanning ? 'Stop scan' : 'Scan'),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (ble.connected.isNotEmpty) ...[
              Text('Connected',
                  style: Theme.of(context).textTheme.titleSmall),
              for (final s in ble.connected)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.bluetooth_connected),
                  title: Text(s.name),
                  subtitle: Text(s.channels
                      .map(_channelLabel)
                      .toList()
                      .join(' · ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.link_off),
                    onPressed: () => ble.disconnect(s.id),
                  ),
                ),
              const Divider(),
            ],
            Text('Found', style: Theme.of(context).textTheme.titleSmall),
            Flexible(
              child: _devices.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        ble.isScanning
                            ? 'Scanning for HR / speed-cadence / power sensors…'
                            : 'No devices found. Tap Scan to search.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _devices.length,
                      itemBuilder: (ctx, i) {
                        final d = _devices[i];
                        final isConnected =
                            ble.connected.any((c) => c.id == d.id);
                        return ListTile(
                          dense: true,
                          leading: Icon(Icons.sensors,
                              color: isConnected
                                  ? Colors.green
                                  : null),
                          title: Text(d.displayName),
                          subtitle: Text(
                              '${d.serviceSummary} · ${d.rssi} dBm'),
                          trailing: isConnected
                              ? const Text('connected')
                              : _connectingId == d.id
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : TextButton(
                                      onPressed: () => _connect(d),
                                      child: const Text('Connect'),
                                    ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String _channelLabel(SensorKind k) => switch (k) {
        SensorKind.heartRate => 'HR',
        SensorKind.cadence => 'Cadence',
        SensorKind.speed => 'Speed',
        SensorKind.power => 'Power',
        SensorKind.temperature => 'Temp',
        SensorKind.barometricElevation => 'Elevation',
      };

  Future<void> _connect(BleDeviceInfo d) async {
    setState(() => _connectingId = d.id);
    final ok = await widget.app.ble.connect(d.id, name: d.displayName);
    if (!mounted) return;
    setState(() => _connectingId = null);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not connect, or the device exposes no supported sensor service.')));
    }
  }
}
