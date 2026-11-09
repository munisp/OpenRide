/// Single-file offline tile store `tiles.mbf` (SPEC §4.2).
///
/// Layout (all integers little-endian):
/// ```
/// 0   4   magic 'MBF1'
/// 4   4   uint32  index entry count N
/// 8   21*N index entries, sorted by (z,x,y) ascending:
///          uint8 z, uint32 x, uint32 y, uint64 blobOffset, uint32 blobLen
/// ..  ..  blob area (concatenated MVT payloads)
/// ```
/// The reader loads the compact index once and binary-searches it; tile blobs
/// are fetched with `RandomAccessFile` reads.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:shared/shared.dart';
import '../tiles/tile_math.dart';

const List<int> _magic = [0x4D, 0x42, 0x46, 0x31]; // 'MBF1'
const int _headerLen = 8;
const int _entryLen = 21;

/// Sort key preserving lexicographic (z, x, y) order.
/// Valid for z <= 255 and x, y < 2^24 (i.e. zoom <= 24).
int _keyOf(TileId id) => (id.z << 48) | (id.x << 24) | id.y;

class MbfWriter {
  final String path;
  final Map<int, (TileId, Uint8List)> _tiles = {};
  bool _finished = false;

  MbfWriter(this.path);

  /// Add (or replace) a tile payload. Tiles may be added in any order;
  /// the index is sorted at [finish].
  void putTile(TileId id, Uint8List mvt) {
    if (_finished) throw StateError('MbfWriter already finished');
    _tiles[_keyOf(id)] = (id, mvt);
  }

  int get tileCount => _tiles.length;

  /// Write header, sorted index and blob area to [path].
  void finish() {
    if (_finished) throw StateError('MbfWriter already finished');
    _finished = true;
    final keys = _tiles.keys.toList()..sort();
    final n = keys.length;
    final out = File(path).openSync(mode: FileMode.write);
    try {
      final header = ByteData(_headerLen + n * _entryLen);
      for (int i = 0; i < 4; i++) {
        header.setUint8(i, _magic[i]);
      }
      header.setUint32(4, n, Endian.little);
      var offset = _headerLen + n * _entryLen;
      var p = _headerLen;
      for (final k in keys) {
        final (id, blob) = _tiles[k]!;
        header.setUint8(p, id.z);
        header.setUint32(p + 1, id.x, Endian.little);
        header.setUint32(p + 5, id.y, Endian.little);
        header.setUint64(p + 9, offset, Endian.little);
        header.setUint32(p + 17, blob.length, Endian.little);
        p += _entryLen;
        offset += blob.length;
      }
      out.writeFromSync(header.buffer.asUint8List());
      for (final k in keys) {
        out.writeFromSync(_tiles[k]!.$2);
      }
    } finally {
      out.closeSync();
    }
  }
}

class MbfReader {
  final String path;
  late final RandomAccessFile _raf;
  late final List<int> _keys; // sorted, parallel to below
  late final List<int> _offsets;
  late final List<int> _lengths;
  late final List<TileId> _ids;

  MbfReader(this.path) {
    _raf = File(path).openSync();
    try {
      final header = _raf.readSync(_headerLen);
      if (header.length < _headerLen ||
          header[0] != _magic[0] ||
          header[1] != _magic[1] ||
          header[2] != _magic[2] ||
          header[3] != _magic[3]) {
        throw FormatException('not an MBF1 file: $path');
      }
      final n = ByteData.sublistView(header).getUint32(4, Endian.little);
      final raw = _raf.readSync(n * _entryLen);
      if (raw.length != n * _entryLen) {
        throw FormatException('truncated MBF index: $path');
      }
      final bd = ByteData.sublistView(raw);
      _keys = List<int>.filled(n, 0);
      _offsets = List<int>.filled(n, 0);
      _lengths = List<int>.filled(n, 0);
      _ids = List<TileId>.filled(n, const TileId(0, 0, 0));
      for (int i = 0; i < n; i++) {
        final p = i * _entryLen;
        final id = TileId(bd.getUint8(p), bd.getUint32(p + 1, Endian.little),
            bd.getUint32(p + 5, Endian.little));
        _ids[i] = id;
        _keys[i] = _keyOf(id);
        _offsets[i] = bd.getUint64(p + 9, Endian.little);
        _lengths[i] = bd.getUint32(p + 17, Endian.little);
      }
    } catch (_) {
      _raf.closeSync();
      rethrow;
    }
  }

  int get tileCount => _keys.length;

  /// All stored tile ids, in sorted (z,x,y) order. Enables iterating a
  /// store, e.g. to merge several stores into one.
  List<TileId> get tileIds => List.unmodifiable(_ids);

  /// Binary search the sorted (z,x,y) index; null when absent.
  Uint8List? getTile(TileId id) {
    final key = _keyOf(id);
    var lo = 0, hi = _keys.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final k = _keys[mid];
      if (k == key) {
        _raf.setPositionSync(_offsets[mid]);
        final data = _raf.readSync(_lengths[mid]);
        if (data.length != _lengths[mid]) {
          throw const FormatException('truncated MBF blob');
        }
        return data;
      }
      if (k < key) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return null;
  }

  /// Distinct zoom levels present, ascending.
  List<int> zooms() {
    final zs = <int>{};
    for (final id in _ids) {
      zs.add(id.z);
    }
    return zs.toList()..sort();
  }

  /// Union of the geographic bounds of all stored tiles.
  GeoBounds bounds() {
    if (_ids.isEmpty) return const GeoBounds(0, 0, 0, 0);
    var minLat = double.infinity, minLon = double.infinity;
    var maxLat = -double.infinity, maxLon = -double.infinity;
    for (final id in _ids) {
      final b = boundsOf(id);
      if (b.minLat < minLat) minLat = b.minLat;
      if (b.minLon < minLon) minLon = b.minLon;
      if (b.maxLat > maxLat) maxLat = b.maxLat;
      if (b.maxLon > maxLon) maxLon = b.maxLon;
    }
    return GeoBounds(minLat, minLon, maxLat, maxLon);
  }

  void close() => _raf.closeSync();
}
