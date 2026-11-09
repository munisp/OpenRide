/// Web-mercator (slippy map / EPSG:3857 tiling scheme) tile math.
library;

import 'dart:math' as math;

import 'package:shared/shared.dart';
import 'mvt.dart';

class TileId {
  final int z, x, y;
  const TileId(this.z, this.x, this.y);

  @override
  bool operator ==(Object o) => o is TileId && o.z == z && o.x == x && o.y == y;
  @override
  int get hashCode => Object.hash(z, x, y);
  @override
  String toString() => '$z/$x/$y';
}

/// Number of tiles along each axis at zoom [z].
int tileCount(int z) => 1 << z;

double _clampLat(double lat) => lat.clamp(-85.05112878, 85.05112878);

/// Tile containing (lat, lon) at zoom [z]. Standard slippy-map formula.
TileId tileFor(double lat, double lon, int z) {
  final n = tileCount(z);
  final clamped = _clampLat(lat);
  var x = ((lon + 180.0) / 360.0 * n).floor();
  final latRad = clamped * math.pi / 180.0;
  var y = ((1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
          2.0 *
          n)
      .floor();
  if (x < 0) x = 0;
  if (x >= n) x = n - 1;
  if (y < 0) y = 0;
  if (y >= n) y = n - 1;
  return TileId(z, x, y);
}

/// WGS-84 bounds covered by [t] (inverse of [tileFor]).
GeoBounds boundsOf(TileId t) {
  final n = tileCount(t.z);
  double lonOf(int x) => x / n * 360.0 - 180.0;
  double latOf(int y) {
    final v = math.pi * (1.0 - 2.0 * y / n);
    return math.atan((math.exp(v) - math.exp(-v)) / 2.0) * 180.0 / math.pi;
  }

  return GeoBounds(latOf(t.y + 1), lonOf(t.x), latOf(t.y), lonOf(t.x + 1));
}

// --- global "extent" coordinates: tile plane of size tileCount(z)*extent ----

/// Longitude -> global X in extent units (0 .. tileCount(z)*extent).
double lonToGlobalX(double lon, int z, {int extent = mvtDefaultExtent}) =>
    (lon + 180.0) / 360.0 * tileCount(z) * extent;

/// Latitude -> global Y in extent units (web mercator).
double latToGlobalY(double lat, int z, {int extent = mvtDefaultExtent}) {
  final clamped = _clampLat(lat);
  final latRad = clamped * math.pi / 180.0;
  return (1.0 - math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) / math.pi) /
      2.0 *
      tileCount(z) *
      extent;
}

/// Global X (extent units) -> longitude.
double globalXToLon(double gx, int z, {int extent = mvtDefaultExtent}) =>
    gx / (tileCount(z) * extent) * 360.0 - 180.0;

/// Global Y (extent units) -> latitude.
double globalYToLat(double gy, int z, {int extent = mvtDefaultExtent}) {
  final n = tileCount(z);
  final v = math.pi * (1.0 - 2.0 * gy / (n * extent));
  return math.atan((math.exp(v) - math.exp(-v)) / 2.0) * 180.0 / math.pi;
}
