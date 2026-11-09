/// Geometry clipping in tile-local integer coordinates.
/// Sutherland–Hodgman for polygon rings, Cohen–Sutherland for linestrings.
library;

import 'mvt.dart';

const int _left = 1, _right = 2, _bottom = 4, _top = 8;

int _outCode(int x, int y, int min, int max) {
  var code = 0;
  if (x < min) {
    code |= _left;
  } else if (x > max) {
    code |= _right;
  }
  if (y < min) {
    code |= _top;
  } else if (y > max) {
    code |= _bottom;
  }
  return code;
}

/// Cohen–Sutherland clip of one segment to [min,max]×[min,max].
/// Returns (x0,y0,x1,y1) or null when fully outside.
List<int>? _clipSegment(int x0, int y0, int x1, int y1, int min, int max) {
  var c0 = _outCode(x0, y0, min, max);
  var c1 = _outCode(x1, y1, min, max);
  var ax = x0, ay = y0, bx = x1, by = y1;
  while (true) {
    if ((c0 | c1) == 0) return [ax, ay, bx, by];
    if ((c0 & c1) != 0) return null;
    final out = c0 != 0 ? c0 : c1;
    int nx, ny;
    // Use fixed-point-ish integer interpolation (round to nearest).
    if (out & _bottom != 0) {
      nx = ax + ((bx - ax) * (max - ay) / (by - ay)).round();
      ny = max;
    } else if (out & _top != 0) {
      nx = ax + ((bx - ax) * (min - ay) / (by - ay)).round();
      ny = min;
    } else if (out & _right != 0) {
      ny = ay + ((by - ay) * (max - ax) / (bx - ax)).round();
      nx = max;
    } else {
      ny = ay + ((by - ay) * (min - ax) / (bx - ax)).round();
      nx = min;
    }
    if (out == c0) {
      ax = nx;
      ay = ny;
      c0 = _outCode(ax, ay, min, max);
    } else {
      bx = nx;
      by = ny;
      c1 = _outCode(bx, by, min, max);
    }
  }
}

/// Clip a polyline to the rectangle [min,max]×[min,max].
/// A polyline leaving and re-entering the box splits into multiple parts.
List<List<MvtPoint>> clipLine(List<MvtPoint> line, int min, int max) {
  final out = <List<MvtPoint>>[];
  if (line.length < 2) return out;
  List<MvtPoint>? current;
  for (int i = 0; i + 1 < line.length; i++) {
    final seg = _clipSegment(line[i].x, line[i].y, line[i + 1].x, line[i + 1].y, min, max);
    if (seg == null) {
      current = null;
      continue;
    }
    final a = MvtPoint(seg[0], seg[1]);
    final b = MvtPoint(seg[2], seg[3]);
    if (current != null && current.last == a) {
      if (current.last != b) current.add(b);
    } else {
      current = [a];
      if (a != b) current.add(b);
      out.add(current);
    }
  }
  out.removeWhere((p) => p.length < 2);
  return out;
}

bool _inside(MvtPoint p, int edge, int min, int max) {
  switch (edge) {
    case _left:
      return p.x >= min;
    case _right:
      return p.x <= max;
    case _top:
      return p.y >= min;
    case _bottom:
      return p.y <= max;
  }
  return false;
}

MvtPoint _intersect(MvtPoint a, MvtPoint b, int edge, int min, int max) {
  // Parametric intersection of segment a->b with the clip edge.
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  switch (edge) {
    case _left:
      return MvtPoint(min, a.y + (dy * (min - a.x) / dx).round());
    case _right:
      return MvtPoint(max, a.y + (dy * (max - a.x) / dx).round());
    case _top:
      return MvtPoint(a.x + (dx * (min - a.y) / dy).round(), min);
    case _bottom:
      return MvtPoint(a.x + (dx * (max - a.y) / dy).round(), max);
  }
  return a;
}

/// Sutherland–Hodgman clip of a single polygon ring against [min,max]×[min,max].
/// Returns the clipped ring (possibly empty); the ring is not explicitly closed.
List<MvtPoint> clipPolygonRing(List<MvtPoint> ring, int min, int max) {
  var output = List<MvtPoint>.of(ring);
  for (final edge in const [_left, _right, _top, _bottom]) {
    if (output.isEmpty) break;
    final input = output;
    output = <MvtPoint>[];
    var s = input.last;
    for (final e in input) {
      if (_inside(e, edge, min, max)) {
        if (!_inside(s, edge, min, max)) {
          output.add(_intersect(s, e, edge, min, max));
        }
        output.add(e);
      } else if (_inside(s, edge, min, max)) {
        output.add(_intersect(s, e, edge, min, max));
      }
      s = e;
    }
  }
  // Remove consecutive duplicates introduced by rounding.
  final cleaned = <MvtPoint>[];
  for (final p in output) {
    if (cleaned.isEmpty || cleaned.last != p) cleaned.add(p);
  }
  if (cleaned.length > 1 && cleaned.first == cleaned.last) {
    cleaned.removeLast();
  }
  return cleaned;
}

/// Clip all rings of a polygon; degenerate rings (<3 points) are dropped.
List<List<MvtPoint>> clipPolygon(List<List<MvtPoint>> rings, int min, int max) {
  final out = <List<MvtPoint>>[];
  for (final ring in rings) {
    var r = ring;
    if (r.length > 1 && r.first == r.last) r = r.sublist(0, r.length - 1);
    final clipped = clipPolygonRing(r, min, max);
    if (clipped.length >= 3) out.add(clipped);
  }
  return out;
}

/// Clip a list of points to the box (keep those inside).
List<MvtPoint> clipPoints(Iterable<MvtPoint> pts, int min, int max) => pts
    .where((p) => p.x >= min && p.x <= max && p.y >= min && p.y <= max)
    .toList();
