/// RideStore — append-only binary ride log + JSON catalog (SPEC §6).
///
/// Layout: `<root>/rides/<id>.trk` + `<root>/catalog.json`.
///
/// .trk format v1:
///   magic "TRK1"
///   then varint-framed records: [varint payloadLen][payload]
///   payload[0] = record type:
///     0x00 header:  varint formatVersion, varint startEpochMs
///     0x01 point:   varint dtMs(delta since prev point; first = since start)
///                   int32LE latE7, int32LE lonE7,
///                   varint flags (bit0 ele,1 speed,2 hr,3 cad,4 power,5 temp)
///                   then per set flag:
///                     ele   zigzag-varint cm
///                     speed varint (m/s * 100)
///                     hr    varint (bpm)
///                     cad   varint (rpm)
///                     power varint (W)
///                     temp  zigzag-varint (C * 10)
///     0x02 stats:   varint-json utf8 of the ride stats map
///     0x03 pause:   varint startEpochMs, varint durationMs
///
/// Crash safety: every record is written and flushed individually; readers
/// silently ignore a truncated trailing frame.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'model.dart';

class RideSummary {
  final String id;
  final DateTime started;
  final double distanceM;
  final double totalTimeS;
  final int pointCount;
  final double calories;

  const RideSummary({
    required this.id,
    required this.started,
    required this.distanceM,
    required this.totalTimeS,
    required this.pointCount,
    required this.calories,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'started': started.millisecondsSinceEpoch,
        'distanceM': distanceM,
        'totalTimeS': totalTimeS,
        'pointCount': pointCount,
        'calories': calories,
      };

  factory RideSummary.fromJson(Map<String, Object?> j) => RideSummary(
        id: j['id'] as String,
        started: DateTime.fromMillisecondsSinceEpoch((j['started'] as num).toInt(), isUtc: true),
        distanceM: (j['distanceM'] as num).toDouble(),
        totalTimeS: (j['totalTimeS'] as num).toDouble(),
        pointCount: (j['pointCount'] as num).toInt(),
        calories: (j['calories'] as num).toDouble(),
      );
}

class RideStore {
  final String rootPath;
  static const List<int> _magic = [0x54, 0x52, 0x4B, 0x31]; // "TRK1"

  RideStore(this.rootPath);

  Directory get _ridesDir => Directory('$rootPath/rides');
  File get _catalogFile => File('$rootPath/catalog.json');

  Future<void> _ensureDirs() async {
    await _ridesDir.create(recursive: true);
  }

  String _trkPath(String id) => '$rootPath/rides/$id.trk';

  /// Appends a single framed record with an immediate flush (crash-safe
  /// append: at most the trailing partial frame is lost).
  Future<void> _appendRecord(RandomAccessFile raf, List<int> payload) async {
    final frame = BytesBuilder();
    _writeVarint(frame, payload.length);
    frame.add(payload);
    await raf.writeFrom(frame.toBytes());
    await raf.flush();
  }

  /// Saves [r]: writes the .trk log record-by-record (flushed per record)
  /// and updates the catalog atomically (tmp + rename).
  Future<Ride> save(Ride r) async {
    await _ensureDirs();
    final file = File(_trkPath(r.id));
    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.writeFrom(_magic);
      await raf.flush();
      final hdr = BytesBuilder()..addByte(0x00);
      _writeVarint(hdr, 1); // format version
      _writeVarint(hdr, r.started.millisecondsSinceEpoch);
      await _appendRecord(raf, hdr.toBytes());

      var prevMs = r.started.millisecondsSinceEpoch;
      for (final p in r.points) {
        await _appendRecord(raf, _encodePoint(p, prevMs));
        prevMs = p.t.toUtc().millisecondsSinceEpoch;
      }

      for (final w in r.pauses) {
        final pb = BytesBuilder()..addByte(0x03);
        _writeVarint(pb, w.start.toUtc().millisecondsSinceEpoch);
        _writeVarint(pb, w.end.toUtc().millisecondsSinceEpoch -
            w.start.toUtc().millisecondsSinceEpoch);
        await _appendRecord(raf, pb.toBytes());
      }

      final statsPayload = BytesBuilder()..addByte(0x02);
      final statsJson = utf8.encode(jsonEncode(
          r.stats.map((k, v) => MapEntry(k, v is double ? v : v.toDouble()))));
      statsPayload.add(statsJson);
      await _appendRecord(raf, statsPayload.toBytes());
    } finally {
      await raf.close();
    }
    await _updateCatalog(r);
    return r;
  }

  List<int> _encodePoint(TrackPoint p, int prevMs) {
    final b = BytesBuilder()..addByte(0x01);
    final ms = p.t.toUtc().millisecondsSinceEpoch;
    _writeVarint(b, ms - prevMs);
    _writeS32(b, (p.lat * 1e7).round());
    _writeS32(b, (p.lon * 1e7).round());
    var flags = 0;
    if (p.ele != null) flags |= 1;
    if (p.speed != null) flags |= 2;
    if (p.hr != null) flags |= 4;
    if (p.cad != null) flags |= 8;
    if (p.power != null) flags |= 16;
    if (p.temp != null) flags |= 32;
    _writeVarint(b, flags);
    if (p.ele != null) _writeZigzag(b, (p.ele! * 100).round());
    if (p.speed != null) _writeVarint(b, (p.speed! * 100).round());
    if (p.hr != null) _writeVarint(b, p.hr!.round());
    if (p.cad != null) _writeVarint(b, p.cad!.round());
    if (p.power != null) _writeVarint(b, p.power!.round());
    if (p.temp != null) _writeZigzag(b, (p.temp! * 10).round());
    return b.toBytes();
  }

  /// Lists all rides, newest first.
  List<RideSummary> list() {
    final f = _catalogFile;
    if (!f.existsSync()) return [];
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      final rides = (j['rides'] as List<dynamic>? ?? [])
          .map((e) => RideSummary.fromJson((e as Map).cast<String, Object?>()))
          .toList();
      rides.sort((a, b) => b.started.compareTo(a.started));
      return rides;
    } on FormatException {
      return []; // corrupted catalog -> treat as empty, do not crash
    }
  }

  /// Loads a ride; truncated trailing frames (crash during append) are
  /// ignored. Stats come from the stored stats record when present,
  /// otherwise are recomputed from the points.
  Future<Ride> load(String id) async {
    final bytes = await File(_trkPath(id)).readAsBytes();
    if (bytes.length < 4 ||
        bytes[0] != _magic[0] ||
        bytes[1] != _magic[1] ||
        bytes[2] != _magic[2] ||
        bytes[3] != _magic[3]) {
      throw const FormatException('not a TRK1 file');
    }
    var pos = 4;
    DateTime? started;
    final points = <TrackPoint>[];
    final pauses = <PauseWindow>[];
    Map<String, num>? stats;
    var prevMs = 0;

    while (pos < bytes.length) {
      final lenRes = _readVarint(bytes, pos);
      if (lenRes == null) break; // truncated frame length
      final len = lenRes.value;
      final frameStart = lenRes.next;
      if (frameStart + len > bytes.length) break; // truncated trailing frame
      final frame = Uint8List.sublistView(bytes, frameStart, frameStart + len);
      pos = frameStart + len;
      if (frame.isEmpty) continue;
      final type = frame[0];
      if (type == 0x00) {
        final v1 = _readVarint(frame, 1);
        final v2 = v1 == null ? null : _readVarint(frame, v1.next);
        if (v2 != null) {
          started = DateTime.fromMillisecondsSinceEpoch(v2.value, isUtc: true);
          prevMs = v2.value;
        }
      } else if (type == 0x01) {
        final p = _decodePoint(frame, prevMs);
        if (p != null) {
          points.add(p);
          prevMs = p.t.millisecondsSinceEpoch;
        }
      } else if (type == 0x02) {
        try {
          final j = jsonDecode(utf8.decode(frame.sublist(1))) as Map<String, dynamic>;
          stats = j.map((k, v) => MapEntry(k, v as num));
        } on FormatException {
          // ignore corrupt stats record; recompute below
        }
      } else if (type == 0x03) {
        final v1 = _readVarint(frame, 1);
        final v2 = v1 == null ? null : _readVarint(frame, v1.next);
        if (v2 != null) {
          final start =
              DateTime.fromMillisecondsSinceEpoch(v1!.value, isUtc: true);
          pauses.add((
            start: start,
            end: start.add(Duration(milliseconds: v2.value)),
          ));
        }
      }
      // unknown record types are skipped (forward compatibility)
    }

    if (started == null) throw const FormatException('missing header record');
    return Ride(
      id: id,
      started: started,
      points: points,
      stats: stats ?? computeRideStats(points, pauses: pauses),
      pauses: pauses,
    );
  }

  TrackPoint? _decodePoint(Uint8List f, int prevMs) {
    var pos = 1;
    final dt = _readVarint(f, pos);
    if (dt == null) return null;
    pos = dt.next;
    if (pos + 8 > f.length) return null;
    final bd = ByteData.sublistView(f, pos, pos + 8);
    final lat = bd.getInt32(0, Endian.little) / 1e7;
    final lon = bd.getInt32(4, Endian.little) / 1e7;
    pos += 8;
    final flags = _readVarint(f, pos);
    if (flags == null) return null;
    pos = flags.next;

    double? ele, speed, hr, cad, power, temp;
    if (flags.value & 1 != 0) {
      final v = _readZigzag(f, pos);
      if (v == null) return null;
      ele = v.value / 100.0;
      pos = v.next;
    }
    if (flags.value & 2 != 0) {
      final v = _readVarint(f, pos);
      if (v == null) return null;
      speed = v.value / 100.0;
      pos = v.next;
    }
    if (flags.value & 4 != 0) {
      final v = _readVarint(f, pos);
      if (v == null) return null;
      hr = v.value.toDouble();
      pos = v.next;
    }
    if (flags.value & 8 != 0) {
      final v = _readVarint(f, pos);
      if (v == null) return null;
      cad = v.value.toDouble();
      pos = v.next;
    }
    if (flags.value & 16 != 0) {
      final v = _readVarint(f, pos);
      if (v == null) return null;
      power = v.value.toDouble();
      pos = v.next;
    }
    if (flags.value & 32 != 0) {
      final v = _readZigzag(f, pos);
      if (v == null) return null;
      temp = v.value / 10.0;
      pos = v.next;
    }
    return TrackPoint(
      DateTime.fromMillisecondsSinceEpoch(prevMs + dt.value, isUtc: true),
      lat,
      lon,
      ele: ele,
      speed: speed,
      hr: hr,
      cad: cad,
      power: power,
      temp: temp,
    );
  }

  void delete(String id) {
    final f = File(_trkPath(id));
    if (f.existsSync()) f.deleteSync();
    final rides = list().where((s) => s.id != id).toList();
    _writeCatalog(rides);
  }

  Future<void> _updateCatalog(Ride r) async {
    final rides = list().where((s) => s.id != r.id).toList();
    rides.add(RideSummary(
      id: r.id,
      started: r.started,
      distanceM: (r.stats['distanceM'] ?? 0).toDouble(),
      totalTimeS: (r.stats['totalTimeS'] ?? 0).toDouble(),
      pointCount: r.points.length,
      calories: (r.stats['calories'] ?? 0).toDouble(),
    ));
    _writeCatalog(rides);
  }

  /// Atomic catalog write: tmp file + rename.
  void _writeCatalog(List<RideSummary> rides) {
    _ridesDir.createSync(recursive: true);
    final tmp = File('$rootPath/catalog.json.tmp');
    tmp.writeAsStringSync(jsonEncode({
      'version': 1,
      'rides': rides.map((s) => s.toJson()).toList(),
    }));
    tmp.renameSync(_catalogFile.path);
  }

  // ---- varint primitives ----

  static void _writeVarint(BytesBuilder b, int v) {
    var x = v;
    while (x > 0x7F) {
      b.addByte((x & 0x7F) | 0x80);
      x >>= 7;
    }
    b.addByte(x);
  }

  static void _writeZigzag(BytesBuilder b, int v) => _writeVarint(b, (v << 1) ^ (v >> 63));

  static void _writeS32(BytesBuilder b, int v) {
    final bd = ByteData(4)..setInt32(0, v, Endian.little);
    b.add(bd.buffer.asUint8List());
  }

  static _VarintRes? _readVarint(List<int> bytes, int pos) {
    var result = 0;
    var shift = 0;
    var i = pos;
    while (i < bytes.length && shift < 64) {
      final byte = bytes[i++];
      result |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return _VarintRes(result, i);
      shift += 7;
    }
    return null;
  }

  static _VarintRes? _readZigzag(List<int> bytes, int pos) {
    final v = _readVarint(bytes, pos);
    if (v == null) return null;
    final u = v.value;
    return _VarintRes((u >> 1) ^ -(u & 1), v.next);
  }
}

class _VarintRes {
  final int value;
  final int next;
  const _VarintRes(this.value, this.next);
}
