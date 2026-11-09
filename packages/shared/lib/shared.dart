/// OpenRide shared geo primitives (SPEC §2).
///
/// Pure Dart, zero dependencies. WGS-84 degrees in, meters out.
library shared;

import 'dart:math' as math;

/// A geographic point in WGS-84 degrees, optionally with elevation (meters).
class GeoPoint {
  final double lat;
  final double lon;
  final double? ele;

  const GeoPoint(this.lat, this.lon, {this.ele});

  static const double earthRadiusM = 6371000.0;

  /// Great-circle distance to [o] in meters (haversine).
  double distanceTo(GeoPoint o) => haversineM(lat, lon, o.lat, o.lon);

  /// Initial bearing to [o] in degrees, normalized to 0..360 (0 = north).
  double bearingTo(GeoPoint o) => initialBearingDeg(lat, lon, o.lat, o.lon);

  /// Point reached travelling [distM] meters along [bearingDeg] from here.
  GeoPoint destination(double bearingDeg, double distM) =>
      destinationPoint(lat, lon, bearingDeg, distM);

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lon == lon && other.ele == ele;

  @override
  int get hashCode => Object.hash(lat, lon, ele);

  @override
  String toString() =>
      'GeoPoint(${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}${ele == null ? '' : ', ele=${ele!.toStringAsFixed(1)}'})';
}

/// Haversine distance in meters between two WGS-84 points.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  final rLat1 = _rad(lat1);
  final rLat2 = _rad(lat2);
  final dLat = rLat2 - rLat1;
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rLat1) * math.cos(rLat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a));
  return GeoPoint.earthRadiusM * c;
}

/// Initial bearing in degrees 0..360 from point 1 to point 2.
double initialBearingDeg(double lat1, double lon1, double lat2, double lon2) {
  final rLat1 = _rad(lat1);
  final rLat2 = _rad(lat2);
  final dLon = _rad(lon2 - lon1);
  final y = math.sin(dLon) * math.cos(rLat2);
  final x = math.cos(rLat1) * math.sin(rLat2) -
      math.sin(rLat1) * math.cos(rLat2) * math.cos(dLon);
  final brng = _deg(math.atan2(y, x));
  return (brng + 360.0) % 360.0;
}

/// Destination point from ([lat],[lon]) travelling [distM] m at [bearingDeg].
GeoPoint destinationPoint(double lat, double lon, double bearingDeg, double distM) {
  final delta = distM / GeoPoint.earthRadiusM;
  final theta = _rad(bearingDeg);
  final rLat1 = _rad(lat);
  final rLon1 = _rad(lon);
  final sinLat2 =
      math.sin(rLat1) * math.cos(delta) + math.cos(rLat1) * math.sin(delta) * math.cos(theta);
  final rLat2 = math.asin(sinLat2.clamp(-1.0, 1.0));
  final rLon2 = rLon1 +
      math.atan2(math.sin(theta) * math.sin(delta) * math.cos(rLat1),
          math.cos(delta) - math.sin(rLat1) * sinLat2);
  return GeoPoint(_deg(rLat2), _deg(rLon2));
}

/// Axis-aligned geographic bounding box.
class GeoBounds {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  const GeoBounds(this.minLat, this.minLon, this.maxLat, this.maxLon);

  /// Smallest bounds containing all [points]. Throws if empty.
  factory GeoBounds.of(Iterable<GeoPoint> points) {
    final it = points.iterator;
    if (!it.moveNext()) {
      throw ArgumentError('GeoBounds.of requires at least one point');
    }
    double minLat = it.current.lat, maxLat = it.current.lat;
    double minLon = it.current.lon, maxLon = it.current.lon;
    while (it.moveNext()) {
      final p = it.current;
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
    }
    return GeoBounds(minLat, minLon, maxLat, maxLon);
  }

  bool contains(GeoPoint p) =>
      p.lat >= minLat && p.lat <= maxLat && p.lon >= minLon && p.lon <= maxLon;

  GeoPoint center() => GeoPoint((minLat + maxLat) / 2, (minLon + maxLon) / 2);

  /// Returns bounds expanded to include [p] (this box unchanged if contained).
  GeoBounds expand(GeoPoint p) => GeoBounds(
        math.min(minLat, p.lat),
        math.min(minLon, p.lon),
        math.max(maxLat, p.lat),
        math.max(maxLon, p.lon),
      );

  /// Returns bounds padded by [marginDeg] on every side.
  GeoBounds padded(double marginDeg) => GeoBounds(
      minLat - marginDeg, minLon - marginDeg, maxLat + marginDeg, maxLon + marginDeg);

  double get widthDeg => maxLon - minLon;
  double get heightDeg => maxLat - minLat;

  @override
  String toString() => 'GeoBounds(($minLat,$minLon)-($maxLat,$maxLon))';
}

/// Alias kept for API parity with SPEC §2 ("LatLngBounds").
typedef LatLngBounds = GeoBounds;

/// Routing profiles (SPEC §2).
enum Profile { trekking, fastbike, roadbike, mtb, carFast, carEco, foot }

// ---------------------------------------------------------------------------
// Polyline6 codec (OSRM-style, precision 6)
// ---------------------------------------------------------------------------

/// Decode an OSRM-style polyline with precision 6.
List<GeoPoint> decodePolyline6(String s) => _decodePolyline(s, 6);

/// Encode points to an OSRM-style polyline with precision 6.
String encodePolyline6(List<GeoPoint> pts) => _encodePolyline(pts, 6);

List<GeoPoint> _decodePolyline(String s, int precision) {
  final factor = math.pow(10, precision).toInt();
  final result = <GeoPoint>[];
  int index = 0;
  int lat = 0, lon = 0;
  while (index < s.length) {
    int shift = 0, value = 0;
    int byte;
    do {
      byte = s.codeUnitAt(index++) - 63;
      value |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < s.length);
    lat += (value & 1) != 0 ? ~(value >> 1) : (value >> 1);
    shift = 0;
    value = 0;
    do {
      byte = s.codeUnitAt(index++) - 63;
      value |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20 && index < s.length);
    lon += (value & 1) != 0 ? ~(value >> 1) : (value >> 1);
    result.add(GeoPoint(lat / factor, lon / factor));
  }
  return result;
}

String _encodePolyline(List<GeoPoint> pts, int precision) {
  final factor = math.pow(10, precision).toInt();
  final out = StringBuffer();
  int prevLat = 0, prevLon = 0;
  for (final p in pts) {
    final lat = (p.lat * factor).round();
    final lon = (p.lon * factor).round();
    _encodeSigned(lat - prevLat, out);
    _encodeSigned(lon - prevLon, out);
    prevLat = lat;
    prevLon = lon;
  }
  return out.toString();
}

void _encodeSigned(int v, StringBuffer out) {
  var value = v < 0 ? ~(v << 1) : (v << 1);
  while (value >= 0x20) {
    out.writeCharCode((0x20 | (value & 0x1f)) + 63);
    value >>= 5;
  }
  out.writeCharCode(value + 63);
}

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

/// Total length of a polyline in meters.
double pathLengthM(List<GeoPoint> pts) {
  double sum = 0;
  for (var i = 1; i < pts.length; i++) {
    sum += pts[i - 1].distanceTo(pts[i]);
  }
  return sum;
}

/// Cumulative distances along a polyline; result[i] = length of pts[0..i].
/// First element is always 0. Length == pts.length.
List<double> cumulativeDistancesM(List<GeoPoint> pts) {
  final out = List<double>.filled(pts.length, 0);
  for (var i = 1; i < pts.length; i++) {
    out[i] = out[i - 1] + pts[i - 1].distanceTo(pts[i]);
  }
  return out;
}

/// Signed turn angle at vertex [b] between segments a->b and b->c, in degrees
/// in (-180, 180]. Positive = right-hand turn, negative = left.
double signedTurnAngle(GeoPoint a, GeoPoint b, GeoPoint c) {
  final b1 = a.bearingTo(b);
  final b2 = b.bearingTo(c);
  var d = b2 - b1;
  while (d > 180) d -= 360;
  while (d <= -180) d += 360;
  return d;
}

double _rad(double deg) => deg * math.pi / 180.0;
double _deg(double rad) => rad * 180.0 / math.pi;
