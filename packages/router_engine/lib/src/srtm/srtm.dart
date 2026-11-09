/// SRTM .hgt elevation reader with bilinear interpolation (SPEC §3.4).
///
/// Tiles live in `<bundle>/srtm/N48E011.hgt` naming. Both 1-arcsec
/// (3601x3601) and 3-arcsec (1201x1201) big-endian int16 grids are
/// supported; the size is derived from the file length.
library srtm;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

class SrtmIndex {
  final String dir;
  final Map<String, _Tile?> _cache = {};

  SrtmIndex(this.dir);

  /// True when `<bundleDir>/srtm` exists (tiles are loaded lazily per name).
  static bool hasTiles(String bundleDir) =>
      Directory('$bundleDir/srtm').existsSync();

  /// True when the given directory itself contains .hgt files.
  static bool dirHasHgt(String srtmDir) =>
      Directory(srtmDir).existsSync();

  /// Elevation in meters at (lat, lon), or null when no tile/data covers it.
  double? elevation(double lat, double lon) {
    if (lat < -90 || lat > 90) return null;
    final nLat = lat.floor();
    final nLon = lon.floor();
    final name = _tileName(nLat, nLon);
    final tile = _cache.putIfAbsent(name, () => _Tile.load(dir, name));
    if (tile == null) return null;
    return tile.sample(lat - nLat, lon - nLon);
  }

  static String _tileName(int lat, int lon) {
    final ns = lat >= 0 ? 'N' : 'S';
    final ew = lon >= 0 ? 'E' : 'W';
    return '$ns${lat.abs().toString().padLeft(2, '0')}'
        '$ew${lon.abs().toString().padLeft(3, '0')}';
  }
}

class _Tile {
  final int size; // samples per axis (1201 or 3601)
  final Int16List data; // big-endian-decoded samples, row-major from north

  _Tile(this.size, this.data);

  static _Tile? load(String dir, String name) {
    final f = File('$dir/srtm/$name.hgt');
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    final samples = bytes.length ~/ 2;
    final size = math.sqrt(samples).round();
    if (size * size != samples) return null; // corrupt
    final bd = ByteData.sublistView(bytes);
    final data = Int16List(samples);
    for (var i = 0; i < samples; i++) {
      data[i] = bd.getInt16(i * 2, Endian.big);
    }
    return _Tile(size, data);
  }

  /// Bilinear sample at fractional offsets [fLat], [fLon] in [0,1] within
  /// the tile. Returns null on void samples (-32768).
  double? sample(double fLat, double fLon) {
    final n = size - 1;
    // Rows run north->south; fLat 0 is the tile's south edge.
    final y = (1.0 - fLat) * n;
    final x = fLon * n;
    final x0 = x.floor().clamp(0, n - 1);
    final y0 = y.floor().clamp(0, n - 1);
    final x1 = x0 + 1;
    final y1 = y0 + 1;
    final fx = x - x0;
    final fy = y - y0;

    double? v(int r, int c) {
      final s = data[r * size + c];
      return s == -32768 ? null : s.toDouble();
    }

    final v00 = v(y0, x0), v01 = v(y0, x1), v10 = v(y1, x0), v11 = v(y1, x1);
    if (v00 == null || v01 == null || v10 == null || v11 == null) {
      // Fall back to the nearest non-void corner.
      final cands = [v00, v01, v10, v11].whereType<double>();
      if (cands.isEmpty) return null;
      return cands.first;
    }
    final top = v00 + (v01 - v00) * fx;
    final bot = v10 + (v11 - v10) * fx;
    return top + (bot - top) * fy;
  }
}
