/// BleSensorAdapter — wraps `flutter_blue_plus` behind a small interface
/// (SPEC §7). Scans/connects to standard BLE cycling sensors and parses the
/// real GATT characteristic formats:
///   * Heart Rate        service 0x180D, characteristic 0x2A37
///   * Cycling Speed &   service 0x1816, characteristic 0x2A5B
///     Cadence (CSC)
///   * Cycling Power     service 0x1818, characteristic 0x2A63
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:ride_core/ride_core.dart' show SensorKind;

/// A parsed sensor sample flowing from a connected BLE device.
class SensorSample {
  final SensorKind kind;
  final double value;
  final DateTime t;

  /// remoteId of the source device (for UI attribution).
  final String deviceId;

  const SensorSample(this.kind, this.value, this.t, this.deviceId);
}

/// A device discovered while scanning.
class BleDeviceInfo {
  final String id; // BluetoothDevice.remoteId.str
  final String name; // advertised name (may be empty)
  final int rssi;
  final bool advertisesHr;
  final bool advertisesCsc;
  final bool advertisesPower;

  const BleDeviceInfo({
    required this.id,
    required this.name,
    required this.rssi,
    this.advertisesHr = false,
    this.advertisesCsc = false,
    this.advertisesPower = false,
  });

  String get displayName => name.isEmpty ? 'Sensor $id' : name;

  String get serviceSummary {
    final parts = <String>[
      if (advertisesHr) 'HR',
      if (advertisesCsc) 'Speed/Cadence',
      if (advertisesPower) 'Power',
    ];
    return parts.isEmpty ? 'BLE device' : parts.join(' · ');
  }
}

/// A currently connected sensor with its subscribed data channels.
class ConnectedSensor {
  final String id;
  final String name;
  final Set<SensorKind> channels;

  const ConnectedSensor({
    required this.id,
    required this.name,
    required this.channels,
  });
}

abstract class BleSensorAdapter implements Listenable {
  Stream<SensorSample> get samples;
  Stream<List<BleDeviceInfo>> get scanResults;
  bool get isScanning;
  List<ConnectedSensor> get connected;

  Future<bool> ensurePermissions();
  Future<void> startScan({Duration timeout});
  Future<void> stopScan();
  Future<bool> connect(String deviceId, {String name});
  Future<void> disconnect(String deviceId);
  Future<void> dispose();
}

class FbpBleSensorAdapter extends ChangeNotifier implements BleSensorAdapter {
  static final Guid _hrMeasurement = Guid('2A37');
  static final Guid _cscMeasurement = Guid('2A5B');
  static final Guid _powerMeasurement = Guid('2A63');

  /// Advertised service UUIDs used to pre-filter the scan.
  static final List<Guid> _filterServices = [
    Guid('180D'),
    Guid('1816'),
    Guid('1818'),
  ];

  /// Wheel circumference used to derive speed from CSC wheel revolutions.
  /// 2096 mm ≈ 700x23c (ISO 47-622), the CPSC/Bluetooth SIG reference value.
  double wheelCircumferenceM = 2.096;

  final _sampleController = StreamController<SensorSample>.broadcast();
  final Map<String, BluetoothDevice> _scanned = {};
  final Map<String, BluetoothDevice> _connected = {};
  final Map<String, Set<SensorKind>> _channels = {};
  final Map<String, String> _names = {};
  final Map<String, _CscState> _cscState = {};
  final List<StreamSubscription<dynamic>> _subs = [];

  StreamSubscription<List<ScanResult>>? _scanKeepAlive;
  bool _scanning = false;

  @override
  Stream<SensorSample> get samples => _sampleController.stream;

  @override
  Stream<List<BleDeviceInfo>> get scanResults =>
      FlutterBluePlus.scanResults.map((results) {
        final out = <BleDeviceInfo>[];
        for (final r in results) {
          final id = r.device.remoteId.str;
          _scanned[id] = r.device;
          final uuids = r.advertisementData.serviceUuids
              .map((g) => g.str.toLowerCase())
              .toList();
          bool advertises(String short16) => uuids.any(
              (u) => u == short16 || u.startsWith('0000$short16-'));
          out.add(BleDeviceInfo(
            id: id,
            name: r.advertisementData.advName,
            rssi: r.rssi,
            advertisesHr: advertises('180d'),
            advertisesCsc: advertises('1816'),
            advertisesPower: advertises('1818'),
          ));
        }
        return out;
      });

  @override
  bool get isScanning => _scanning;

  @override
  List<ConnectedSensor> get connected => [
        for (final id in _connected.keys)
          ConnectedSensor(
            id: id,
            name: _names[id] ?? id,
            channels: Set.unmodifiable(_channels[id] ?? const <SensorKind>{}),
          ),
      ];

  @override
  Future<bool> ensurePermissions() async {
    // Android 12+ runtime permissions; already-granted / not-applicable on
    // other platforms resolve as granted/limited.
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  @override
  Future<void> startScan(
      {Duration timeout = const Duration(seconds: 15)}) async {
    if (!await ensurePermissions()) {
      throw StateError('Bluetooth permissions not granted');
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      final on = await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first
          .timeout(const Duration(seconds: 5),
              onTimeout: () => BluetoothAdapterState.unknown);
      if (on != BluetoothAdapterState.on) {
        throw StateError('Bluetooth adapter is off');
      }
    }
    // Keep the results cache warm for the lifetime of the adapter.
    _scanKeepAlive ??=
        FlutterBluePlus.scanResults.listen((_) {}, onError: (Object _) {});
    _scanning = true;
    notifyListeners();
    await FlutterBluePlus.startScan(
      withServices: _filterServices,
      timeout: timeout,
    );
    _subs.add(FlutterBluePlus.isScanning.listen((scanning) {
      if (!scanning && _scanning) {
        _scanning = false;
        notifyListeners();
      }
    }));
  }

  @override
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    _scanning = false;
    notifyListeners();
  }

  @override
  Future<bool> connect(String deviceId, {String name = ''}) async {
    final device = _scanned[deviceId];
    if (device == null) return false;
    try {
      await device.connect(timeout: const Duration(seconds: 15));
    } on Exception {
      return false;
    }
    _connected[deviceId] = device;
    _names[deviceId] = name.isEmpty ? deviceId : name;
    _channels[deviceId] = <SensorKind>{};
    _cscState[deviceId] = _CscState();
    notifyListeners();

    // Reflect remote disconnects in the model.
    _subs.add(device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        _connected.remove(deviceId);
        _channels.remove(deviceId);
        _names.remove(deviceId);
        _cscState.remove(deviceId);
        notifyListeners();
      }
    }));

    List<BluetoothService> services;
    try {
      services = await device.discoverServices();
    } on Exception {
      await _teardown(deviceId);
      return false;
    }

    for (final service in services) {
      for (final c in service.characteristics) {
        if (!c.properties.notify && !c.properties.indicate) continue;
        if (c.uuid == _hrMeasurement) {
          await _subscribe(device, c, (v) => _parseHr(deviceId, v));
          _channels[deviceId]!.add(SensorKind.heartRate);
        } else if (c.uuid == _cscMeasurement) {
          await _subscribe(device, c, (v) => _parseCsc(deviceId, v));
          _channels[deviceId]!
              .addAll({SensorKind.cadence, SensorKind.speed});
        } else if (c.uuid == _powerMeasurement) {
          await _subscribe(device, c, (v) => _parsePower(deviceId, v));
          _channels[deviceId]!.add(SensorKind.power);
        }
      }
    }
    if (_channels[deviceId]!.isEmpty) {
      await _teardown(deviceId);
      return false; // not a sensor we understand
    }
    notifyListeners();
    return true;
  }

  Future<void> _subscribe(BluetoothDevice device, BluetoothCharacteristic c,
      void Function(List<int> value) onValue) async {
    final sub = c.onValueReceived.listen(onValue, onError: (Object _) {});
    device.cancelWhenDisconnected(sub);
    _subs.add(sub);
    await c.setNotifyValue(true);
  }

  Future<void> _teardown(String deviceId) async {
    final d = _connected.remove(deviceId);
    _channels.remove(deviceId);
    _names.remove(deviceId);
    _cscState.remove(deviceId);
    if (d != null) {
      try {
        await d.disconnect();
      } on Exception {
        // already gone
      }
    }
    notifyListeners();
  }

  @override
  Future<void> disconnect(String deviceId) => _teardown(deviceId);

  // ---------------------------------------------------------------------------
  // GATT parsers (Bluetooth SIG specifications)
  // ---------------------------------------------------------------------------

  /// Heart Rate Measurement (0x2A37): byte0 flags; bit0 selects uint8/uint16
  /// heart-rate value.
  void _parseHr(String deviceId, List<int> v) {
    if (v.length < 2) return;
    final flags = v[0];
    final int bpm;
    if (flags & 0x01 != 0) {
      if (v.length < 3) return;
      bpm = v[1] | (v[2] << 8);
    } else {
      bpm = v[1];
    }
    if (bpm <= 0) return;
    _emit(SensorKind.heartRate, bpm.toDouble(), deviceId);
  }

  /// CSC Measurement (0x2A5B): byte0 flags; bit0 → wheel revolution data
  /// (uint32 cumulative revs + uint16 last event time, 1/1024 s); bit1 →
  /// crank revolution data (uint16 revs + uint16 time). Rates are computed
  /// from deltas, handling natural uint16/uint32 wrap-around.
  void _parseCsc(String deviceId, List<int> v) {
    if (v.isEmpty) return;
    final st = _cscState[deviceId] ??= _CscState();
    final flags = v[0];
    var i = 1;

    if (flags & 0x01 != 0) {
      if (v.length < i + 6) return;
      final wheelRevs = _u32(v, i);
      final wheelTime = _u16(v, i + 4);
      i += 6;
      if (st.hasWheel) {
        final dRevs = (wheelRevs - st.wheelRevs) & 0xFFFFFFFF;
        final dTicks = (wheelTime - st.wheelTime) & 0xFFFF;
        if (dTicks > 0 && dRevs > 0 && dRevs < 100) {
          final dtS = dTicks / 1024.0;
          final speed = dRevs * wheelCircumferenceM / dtS;
          if (speed >= 0 && speed < 45) {
            _emit(SensorKind.speed, speed, deviceId);
          }
        }
      }
      st.wheelRevs = wheelRevs;
      st.wheelTime = wheelTime;
      st.hasWheel = true;
    }

    if (flags & 0x02 != 0) {
      if (v.length < i + 4) return;
      final crankRevs = _u16(v, i);
      final crankTime = _u16(v, i + 2);
      if (st.hasCrank) {
        final dRevs = (crankRevs - st.crankRevs) & 0xFFFF;
        final dTicks = (crankTime - st.crankTime) & 0xFFFF;
        if (dTicks > 0 && dRevs > 0 && dRevs < 32) {
          final dtS = dTicks / 1024.0;
          final rpm = dRevs * 60.0 / dtS;
          if (rpm >= 0 && rpm < 255) {
            _emit(SensorKind.cadence, rpm, deviceId);
          }
        }
      }
      st.crankRevs = crankRevs;
      st.crankTime = crankTime;
      st.hasCrank = true;
    }
  }

  /// Cycling Power Measurement (0x2A63): uint16 flags, then sint16
  /// instantaneous power (W) little-endian.
  void _parsePower(String deviceId, List<int> v) {
    if (v.length < 4) return;
    var watts = v[2] | (v[3] << 8);
    if (watts >= 0x8000) watts -= 0x10000; // sint16
    if (watts < 0 || watts > 4000) return; // physically implausible
    _emit(SensorKind.power, watts.toDouble(), deviceId);
  }

  static int _u16(List<int> v, int i) => v[i] | (v[i + 1] << 8);
  static int _u32(List<int> v, int i) =>
      v[i] | (v[i + 1] << 8) | (v[i + 2] << 16) | (v[i + 3] << 24);

  void _emit(SensorKind kind, double value, String deviceId) {
    _sampleController
        .add(SensorSample(kind, value, DateTime.now().toUtc(), deviceId));
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _scanKeepAlive?.cancel();
    for (final id in _connected.keys.toList()) {
      await _teardown(id);
    }
    await _sampleController.close();
  }
}

/// Per-connection CSC rolling counters.
class _CscState {
  int wheelRevs = 0;
  int wheelTime = 0;
  int crankRevs = 0;
  int crankTime = 0;
  bool hasWheel = false;
  bool hasCrank = false;
}
