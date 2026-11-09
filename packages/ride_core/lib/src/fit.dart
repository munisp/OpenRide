/// Real FIT binary protocol writer (SPEC §6).
///
/// Layout: 14-byte header (size, protocol 0x10, profile version, data size,
/// ".FIT" magic, header CRC-16) + definition/data record stream + file
/// CRC-16 (FIT nibble table). Little-endian base types, local message
/// types, FIT epoch timestamps (seconds since 1989-12-31T00:00:00Z,
/// offset 631065600), semicircle positions (sint32), and the profile
/// scale/offset encodings (distance 100, speed 1000, altitude 5/500).
library;

import 'dart:typed_data';

import 'model.dart';

/// FIT epoch offset: seconds between 1970-01-01 and 1989-12-31 UTC.
const int kFitEpochOffset = 631065600;

// Base type identifiers (with endian bit set where applicable).
const int _tEnum = 0x00;
const int _tSint8 = 0x01;
const int _tUint8 = 0x02;
const int _tSint16 = 0x83;
const int _tUint16 = 0x84;
const int _tSint32 = 0x85;
const int _tUint32 = 0x86;
const int _tUint32z = 0x8C;

const int _invalidU8 = 0xFF;
const int _invalidU16 = 0xFFFF;
const int _invalidS8 = 0x7F;
const int _invalidS32 = 0x7FFFFFFF;

/// FIT CRC-16 using the official nibble lookup table.
class FitCrc {
  // Official FIT SDK nibble table (crc.c, FIT protocol documentation).
  static const List<int> _table = [
    0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401,
    0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400,
  ];

  int value = 0;

  void update(int byte) {
    var crc = value;
    var tmp = _table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ tmp ^ _table[byte & 0xF];
    tmp = _table[crc & 0xF];
    crc = (crc >> 4) & 0x0FFF;
    crc = crc ^ tmp ^ _table[(byte >> 4) & 0xF];
    value = crc;
  }

  void updateAll(List<int> bytes) {
    for (final b in bytes) {
      update(b);
    }
  }

  static int of(List<int> bytes) {
    final c = FitCrc();
    c.updateAll(bytes);
    return c.value;
  }
}

class _FieldDef {
  final int num, size, type;
  const _FieldDef(this.num, this.size, this.type);
}

/// Low-level FIT message stream encoder (definition + data messages,
/// normal headers, little-endian).
class FitEncoder {
  final BytesBuilder _out = BytesBuilder();

  void writeDefinition(int localType, int globalMsgNum, List<_FieldDef> fields) {
    _out.addByte(0x40 | (localType & 0x0F)); // normal header, definition bit
    _out.addByte(0); // reserved
    _out.addByte(0); // architecture: little-endian
    _out.addByte(globalMsgNum & 0xFF);
    _out.addByte((globalMsgNum >> 8) & 0xFF);
    _out.addByte(fields.length);
    for (final f in fields) {
      _out.addByte(f.num);
      _out.addByte(f.size);
      _out.addByte(f.type);
    }
  }

  /// [values] must match the field definition order; each value is an int
  /// already scaled/offset to the raw stored representation.
  void writeData(int localType, List<int> values, List<_FieldDef> fields) {
    _out.addByte(localType & 0x0F);
    for (var i = 0; i < fields.length; i++) {
      final v = values[i];
      switch (fields[i].type) {
        case _tEnum:
        case _tUint8:
          _out.addByte(v & 0xFF);
          break;
        case _tSint8:
          _out.addByte(v & 0xFF);
          break;
        case _tSint16:
        case _tUint16:
          _out.addByte(v & 0xFF);
          _out.addByte((v >> 8) & 0xFF);
          break;
        case _tSint32:
        case _tUint32:
        case _tUint32z:
          _out.addByte(v & 0xFF);
          _out.addByte((v >> 8) & 0xFF);
          _out.addByte((v >> 16) & 0xFF);
          _out.addByte((v >> 24) & 0xFF);
          break;
        default:
          throw ArgumentError('unsupported base type ${fields[i].type}');
      }
    }
  }

  Uint8List get data => _out.toBytes();
}

int _fitTime(DateTime t) => (t.toUtc().millisecondsSinceEpoch ~/ 1000) - kFitEpochOffset;

int _semicircles(double deg) => (deg * (2147483648.0 / 180.0)).round();

int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

// local message type assignments
const int _localFileId = 0;
const int _localRecord = 1;
const int _localLap = 2;
const int _localSession = 3;
const int _localActivity = 4;

const _fileIdDef = [
  _FieldDef(0, 1, _tEnum), // type
  _FieldDef(1, 2, _tUint16), // manufacturer
  _FieldDef(2, 2, _tUint16), // product
  _FieldDef(3, 4, _tUint32z), // serial_number
  _FieldDef(4, 4, _tUint32), // time_created
];

const _recordDef = [
  _FieldDef(253, 4, _tUint32), // timestamp
  _FieldDef(0, 4, _tSint32), // position_lat (semicircles)
  _FieldDef(1, 4, _tSint32), // position_long (semicircles)
  _FieldDef(2, 2, _tUint16), // altitude (scale 5, offset 500)
  _FieldDef(3, 1, _tUint8), // heart_rate
  _FieldDef(4, 1, _tUint8), // cadence
  _FieldDef(5, 4, _tUint32), // distance (scale 100)
  _FieldDef(6, 2, _tUint16), // speed (scale 1000)
  _FieldDef(7, 2, _tUint16), // power
  _FieldDef(13, 1, _tSint8), // temperature
];

const _lapDef = [
  _FieldDef(254, 2, _tUint16), // message_index
  _FieldDef(253, 4, _tUint32), // timestamp
  _FieldDef(0, 1, _tEnum), // event
  _FieldDef(1, 1, _tEnum), // event_type
  _FieldDef(2, 4, _tUint32), // start_time
  _FieldDef(3, 4, _tSint32), // start_position_lat
  _FieldDef(4, 4, _tSint32), // start_position_long
  _FieldDef(5, 4, _tSint32), // end_position_lat
  _FieldDef(6, 4, _tSint32), // end_position_long
  _FieldDef(7, 4, _tUint32), // total_elapsed_time (scale 1000)
  _FieldDef(8, 4, _tUint32), // total_timer_time (scale 1000)
  _FieldDef(9, 4, _tUint32), // total_distance (scale 100)
  _FieldDef(11, 2, _tUint16), // total_calories
  _FieldDef(13, 2, _tUint16), // avg_speed (scale 1000)
  _FieldDef(14, 2, _tUint16), // max_speed (scale 1000)
  _FieldDef(15, 1, _tUint8), // avg_heart_rate
  _FieldDef(16, 1, _tUint8), // max_heart_rate
  _FieldDef(17, 1, _tUint8), // avg_cadence
  _FieldDef(18, 1, _tUint8), // max_cadence
  _FieldDef(19, 2, _tUint16), // avg_power
  _FieldDef(20, 2, _tUint16), // max_power
  _FieldDef(21, 2, _tUint16), // total_ascent
  _FieldDef(22, 2, _tUint16), // total_descent
  _FieldDef(24, 1, _tEnum), // lap_trigger
  _FieldDef(25, 1, _tEnum), // sport
];

const _sessionDef = [
  _FieldDef(254, 2, _tUint16), // message_index
  _FieldDef(253, 4, _tUint32), // timestamp
  _FieldDef(0, 1, _tEnum), // event
  _FieldDef(1, 1, _tEnum), // event_type
  _FieldDef(2, 4, _tUint32), // start_time
  _FieldDef(3, 4, _tSint32), // start_position_lat
  _FieldDef(4, 4, _tSint32), // start_position_long
  _FieldDef(5, 1, _tEnum), // sport
  _FieldDef(6, 1, _tEnum), // sub_sport
  _FieldDef(7, 4, _tUint32), // total_elapsed_time (scale 1000)
  _FieldDef(8, 4, _tUint32), // total_timer_time (scale 1000)
  _FieldDef(9, 4, _tUint32), // total_distance (scale 100)
  _FieldDef(11, 2, _tUint16), // total_calories
  _FieldDef(14, 2, _tUint16), // avg_speed (scale 1000)
  _FieldDef(15, 2, _tUint16), // max_speed (scale 1000)
  _FieldDef(16, 1, _tUint8), // avg_heart_rate
  _FieldDef(17, 1, _tUint8), // max_heart_rate
  _FieldDef(18, 1, _tUint8), // avg_cadence
  _FieldDef(19, 1, _tUint8), // max_cadence
  _FieldDef(20, 2, _tUint16), // avg_power
  _FieldDef(21, 2, _tUint16), // max_power
  _FieldDef(22, 2, _tUint16), // total_ascent
  _FieldDef(23, 2, _tUint16), // total_descent
  _FieldDef(25, 2, _tUint16), // first_lap_index
  _FieldDef(26, 2, _tUint16), // num_laps
  _FieldDef(28, 1, _tEnum), // trigger
  _FieldDef(29, 4, _tSint32), // nec_lat
  _FieldDef(30, 4, _tSint32), // nec_long
  _FieldDef(31, 4, _tSint32), // swc_lat
  _FieldDef(32, 4, _tSint32), // swc_long
];

const _activityDef = [
  _FieldDef(253, 4, _tUint32), // timestamp
  _FieldDef(0, 4, _tUint32), // total_timer_time (scale 1000)
  _FieldDef(1, 2, _tUint16), // num_sessions
  _FieldDef(2, 1, _tEnum), // type
  _FieldDef(3, 1, _tEnum), // event
  _FieldDef(4, 1, _tEnum), // event_type
  _FieldDef(5, 4, _tUint32), // local_timestamp
  _FieldDef(6, 1, _tUint8), // event_group
];

/// Serializes [r] to a FIT activity file (sport cycling).
Uint8List toFit(Ride r) {
  final enc = FitEncoder();
  final s = r.stats;
  final pts = r.points;

  // ---- file_id ----
  enc.writeDefinition(_localFileId, 0, _fileIdDef);
  enc.writeData(_localFileId, [
    4, // file type: activity
    255, // manufacturer: development
    1001, // product
    (r.started.millisecondsSinceEpoch & 0xFFFFFFFF), // serial_number
    _fitTime(r.started), // time_created
  ], _fileIdDef);

  // ---- record stream ----
  enc.writeDefinition(_localRecord, 20, _recordDef);
  final cumDistances = cumulativeDistances(pts, pauses: r.pauses);
  for (var i = 0; i < pts.length; i++) {
    final p = pts[i];
    final cumM = cumDistances[i];
    final alt = p.ele == null
        ? _invalidU16
        : _clamp(((p.ele! + 500.0) * 5.0).round(), 0, 0xFFFE);
    final spd = p.speed == null
        ? _invalidU16
        : _clamp((p.speed! * 1000.0).round(), 0, 0xFFFE);
    final temp = p.temp == null ? _invalidS8 : _clamp(p.temp!.round(), -128, 126);
    enc.writeData(_localRecord, [
      _fitTime(p.t),
      _semicircles(p.lat),
      _semicircles(p.lon),
      alt,
      p.hr == null ? _invalidU8 : _clamp(p.hr!.round(), 0, 254),
      p.cad == null ? _invalidU8 : _clamp(p.cad!.round(), 0, 254),
      _clamp((cumM * 100.0).round(), 0, 0xFFFFFFFE),
      spd,
      p.power == null ? _invalidU16 : _clamp(p.power!.round(), 0, 0xFFFE),
      temp,
    ], _recordDef);
  }

  if (pts.isEmpty) {
    // still emit a valid summary-only file
  }

  final first = pts.isNotEmpty ? pts.first : null;
  final last = pts.isNotEmpty ? pts.last : null;
  final end = last?.t ?? r.started;
  final totalS = (s['totalTimeS'] ?? 0).toDouble();
  final dist = (s['distanceM'] ?? 0).toDouble();
  final kcal = (s['calories'] ?? 0).toDouble();
  final avgSpd = (s['avgSpeedMps'] ?? 0).toDouble();
  final maxSpd = (s['maxSpeedMps'] ?? 0).toDouble();
  final avgHr = (s['avgHr'] ?? 0).toDouble();
  final maxHr = (s['maxHr'] ?? 0).toDouble();
  final avgCad = (s['avgCadence'] ?? 0).toDouble();
  final maxCad = (s['maxCadence'] ?? 0).toDouble();
  final avgPwr = (s['avgPower'] ?? 0).toDouble();
  final maxPwr = (s['maxPower'] ?? 0).toDouble();
  final gain = (s['elevationGainM'] ?? 0).toDouble();
  final loss = (s['elevationLossM'] ?? 0).toDouble();

  int u16(double v) => _clamp(v.round(), 0, 0xFFFE);
  int u8(double v) => _clamp(v.round(), 0, 254);
  int u32ms(double sec) => _clamp((sec * 1000.0).round(), 0, 0xFFFFFFFE);
  int u32c(double m) => _clamp((m * 100.0).round(), 0, 0xFFFFFFFE);
  int spd16(double mps) => _clamp((mps * 1000.0).round(), 0, 0xFFFE);

  // ---- lap ----
  enc.writeDefinition(_localLap, 19, _lapDef);
  enc.writeData(_localLap, [
    0, // message_index
    _fitTime(end),
    7, // event: lap
    1, // event_type: stop
    _fitTime(r.started),
    first == null ? _invalidS32 : _semicircles(first.lat),
    first == null ? _invalidS32 : _semicircles(first.lon),
    last == null ? _invalidS32 : _semicircles(last.lat),
    last == null ? _invalidS32 : _semicircles(last.lon),
    u32ms(totalS),
    u32ms(totalS), // timer time (pauses excluded from stats already)
    u32c(dist),
    u16(kcal),
    spd16(avgSpd),
    spd16(maxSpd),
    avgHr > 0 ? u8(avgHr) : _invalidU8,
    maxHr > 0 ? u8(maxHr) : _invalidU8,
    avgCad > 0 ? u8(avgCad) : _invalidU8,
    maxCad > 0 ? u8(maxCad) : _invalidU8,
    avgPwr > 0 ? u16(avgPwr) : _invalidU16,
    maxPwr > 0 ? u16(maxPwr) : _invalidU16,
    u16(gain),
    u16(loss),
    7, // lap_trigger: session_end
    2, // sport: cycling
  ], _lapDef);

  // ---- session ----
  final hasPos = first != null && last != null;
  double minLat = 0, maxLat = 0, minLon = 0, maxLon = 0;
  if (hasPos) {
    minLat = maxLat = first.lat;
    minLon = maxLon = first.lon;
    for (final p in pts) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
  }
  enc.writeDefinition(_localSession, 18, _sessionDef);
  enc.writeData(_localSession, [
    0, // message_index
    _fitTime(end),
    6, // event: session
    1, // event_type: stop
    _fitTime(r.started),
    first == null ? _invalidS32 : _semicircles(first.lat),
    first == null ? _invalidS32 : _semicircles(first.lon),
    2, // sport: cycling
    0, // sub_sport: generic
    u32ms(totalS),
    u32ms(totalS),
    u32c(dist),
    u16(kcal),
    spd16(avgSpd),
    spd16(maxSpd),
    avgHr > 0 ? u8(avgHr) : _invalidU8,
    maxHr > 0 ? u8(maxHr) : _invalidU8,
    avgCad > 0 ? u8(avgCad) : _invalidU8,
    maxCad > 0 ? u8(maxCad) : _invalidU8,
    avgPwr > 0 ? u16(avgPwr) : _invalidU16,
    maxPwr > 0 ? u16(maxPwr) : _invalidU16,
    u16(gain),
    u16(loss),
    0, // first_lap_index
    1, // num_laps
    0, // trigger: activity_end
    hasPos ? _semicircles(maxLat) : _invalidS32, // nec_lat
    hasPos ? _semicircles(maxLon) : _invalidS32, // nec_long
    hasPos ? _semicircles(minLat) : _invalidS32, // swc_lat
    hasPos ? _semicircles(minLon) : _invalidS32, // swc_long
  ], _sessionDef);

  // ---- activity ----
  enc.writeDefinition(_localActivity, 34, _activityDef);
  enc.writeData(_localActivity, [
    _fitTime(end),
    u32ms(totalS),
    1, // num_sessions
    0, // type: manual
    26, // event: activity
    1, // event_type: stop
    _fitTime(end), // local_timestamp (device keeps UTC, fully offline)
    0xFF, // event_group: invalid
  ], _activityDef);

  final data = enc.data;

  // ---- header ----
  final header = BytesBuilder();
  header.addByte(14); // header size
  header.addByte(0x10); // protocol version 1.0
  _u16le(header, 2135); // profile version 21.35
  _u32le(header, data.length);
  header.add('.FIT'.codeUnits);
  final headerBytes = header.toBytes();
  _u16le(header, FitCrc.of(headerBytes));
  final fullHeader = header.toBytes();

  // ---- assemble + file CRC ----
  final fileCrc = FitCrc();
  fileCrc.updateAll(data);
  final out = BytesBuilder();
  out.add(fullHeader);
  out.add(data);
  _u16le(out, fileCrc.value);
  return out.toBytes();
}

void _u16le(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
}

void _u32le(BytesBuilder b, int v) {
  b.addByte(v & 0xFF);
  b.addByte((v >> 8) & 0xFF);
  b.addByte((v >> 16) & 0xFF);
  b.addByte((v >> 24) & 0xFF);
}
