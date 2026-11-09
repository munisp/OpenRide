/// Minimal FIT binary protocol READER for round-trip tests.
/// Verifies header CRC, file CRC, parses definition + data messages and
/// decodes fields using the same base types the writer emits.
library;

import 'dart:typed_data';

import '../src/fit.dart' show FitCrc, kFitEpochOffset;

class FitFieldValue {
  final int num;
  final int raw; // raw integer value as stored
  const FitFieldValue(this.num, this.raw);
}

class FitMessage {
  final int globalNum;
  final Map<int, int> fields; // field num -> raw value
  FitMessage(this.globalNum, this.fields);

  bool has(int num) => fields.containsKey(num);
  int operator [](int num) => fields[num] ?? (throw ArgumentError('field $num missing'));

  double scaled(int num, num scale, [num offset = 0]) => fields[num]! / scale - offset;
}

class FitFile {
  final int protocolVersion;
  final int profileVersion;
  final List<FitMessage> messages;
  FitFile(this.protocolVersion, this.profileVersion, this.messages);

  List<FitMessage> ofType(int globalNum) =>
      messages.where((m) => m.globalNum == globalNum).toList();

  static DateTime fitTimeToUtc(int fitSeconds) =>
      DateTime.fromMillisecondsSinceEpoch((fitSeconds + kFitEpochOffset) * 1000, isUtc: true);

  static double semicirclesToDeg(int semi) => semi * (180.0 / 2147483648.0);
}

class _Def {
  final int globalNum;
  final List<(int num, int size, int type)> fields;
  const _Def(this.globalNum, this.fields);
  int get totalSize => fields.fold(0, (a, f) => a + f.$2);
}

class FitParseException implements Exception {
  final String message;
  const FitParseException(this.message);
  @override
  String toString() => 'FitParseException: $message';
}

/// Parses and fully validates a FIT file. Throws [FitParseException] on any
/// structural or checksum violation.
FitFile parseFit(Uint8List bytes) {
  if (bytes.length < 16) throw const FitParseException('too short');
  final headerSize = bytes[0];
  if (headerSize != 14 && headerSize != 12) {
    throw FitParseException('bad header size $headerSize');
  }
  final protocol = bytes[1];
  final bd = ByteData.sublistView(bytes);
  final profile = bd.getUint16(2, Endian.little);
  final dataSize = bd.getUint32(4, Endian.little);
  final magic = String.fromCharCodes(bytes.sublist(8, 12));
  if (magic != '.FIT') throw FitParseException('bad magic $magic');
  if (headerSize == 14) {
    final headerCrc = bd.getUint16(12, Endian.little);
    final computed = FitCrc.of(bytes.sublist(0, 12));
    if (headerCrc != computed) {
      throw FitParseException('header CRC mismatch: file=$headerCrc computed=$computed');
    }
  }
  if (headerSize + dataSize + 2 != bytes.length) {
    throw FitParseException(
        'size mismatch: header=$headerSize data=$dataSize total=${bytes.length}');
  }
  final fileCrc = bd.getUint16(bytes.length - 2, Endian.little);
  final computedFileCrc = FitCrc.of(bytes.sublist(headerSize, headerSize + dataSize));
  if (fileCrc != computedFileCrc) {
    throw FitParseException('file CRC mismatch: file=$fileCrc computed=$computedFileCrc');
  }

  final defs = <int, _Def>{};
  final messages = <FitMessage>[];
  var pos = headerSize;
  final end = headerSize + dataSize;
  while (pos < end) {
    final header = bytes[pos++];
    if (header & 0x80 != 0) {
      throw const FitParseException('compressed timestamp headers not supported by test reader');
    }
    final localType = header & 0x0F;
    if (header & 0x40 != 0) {
      // definition message
      pos++; // reserved
      final arch = bytes[pos++];
      if (arch != 0) {
        throw const FitParseException('big-endian not supported by test reader');
      }
      final global = bytes[pos] | (bytes[pos + 1] << 8);
      pos += 2;
      final nFields = bytes[pos++];
      final fields = <(int, int, int)>[];
      for (var i = 0; i < nFields; i++) {
        fields.add((bytes[pos], bytes[pos + 1], bytes[pos + 2]));
        pos += 3;
      }
      defs[localType] = _Def(global, fields);
    } else {
      final def = defs[localType];
      if (def == null) throw FitParseException('data message for undefined local type $localType');
      if (pos + def.totalSize > end) throw const FitParseException('data message overruns');
      final mbd = ByteData.sublistView(bytes, pos, pos + def.totalSize);
      var off = 0;
      final values = <int, int>{};
      for (final f in def.fields) {
        values[f.$1] = _decode(mbd, off, f.$2, f.$3);
        off += f.$2;
      }
      pos += def.totalSize;
      messages.add(FitMessage(def.globalNum, values));
    }
  }
  if (pos != end) throw const FitParseException('trailing garbage in data section');
  return FitFile(protocol, profile, messages);
}

int _decode(ByteData bd, int off, int size, int baseType) {
  switch (baseType) {
    case 0x00: // enum
    case 0x02: // uint8
      return bd.getUint8(off);
    case 0x01: // sint8
      return bd.getInt8(off);
    case 0x0A: // uint8z
      return bd.getUint8(off);
    case 0x83: // sint16
      return bd.getInt16(off, Endian.little);
    case 0x84: // uint16
      return bd.getUint16(off, Endian.little);
    case 0x8B: // uint16z
      return bd.getUint16(off, Endian.little);
    case 0x85: // sint32
      return bd.getInt32(off, Endian.little);
    case 0x86: // uint32
    case 0x8C: // uint32z
      return bd.getUint32(off, Endian.little);
    default:
      throw FitParseException('unsupported base type 0x${baseType.toRadixString(16)}');
  }
}
