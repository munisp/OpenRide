/// OfflineMap — a CustomPainter-driven slippy-map widget painting maps_core
/// DrawCommands from the active bundle's tiles.mbf (SPEC §7). Supports pan,
/// pinch zoom, double-tap zoom, long-press callbacks, route polyline overlay,
/// waypoint markers and a live position/heading marker.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maps_core/maps_core.dart';

import 'tile_source.dart';

/// Marker kinds painted by the map.
enum MapMarkerKind { start, end, via }

class MapMarker {
  final GeoPoint point;
  final MapMarkerKind kind;

  /// Via markers are numbered (1-based).
  final int label;

  const MapMarker(this.point, this.kind, {this.label = 0});
}

/// Viewport + overlay state for [OfflineMap]. ChangeNotifier so the painter
/// repaints efficiently and screens can react.
class OfflineMapController extends ChangeNotifier {
  MapTileSource? tileSource;

  GeoPoint _center = const GeoPoint(51.05, 13.74); // Dresden until located
  double _zoom = 12.0;

  GeoPoint get center => _center;
  double get zoom => _zoom;

  /// Overlays
  List<GeoPoint> route = const [];
  List<MapMarker> markers = const [];
  GeoPoint? position;
  double? headingDeg;
  bool followPosition = false;

  /// Integer zoom actually used for tile selection.
  int get tileZoom {
    final zs = tileSource?.zooms ?? const <int>[];
    if (zs.isEmpty) return _zoom.floor().clamp(0, 19).toInt();
    var zi = _zoom.floor();
    if (zi < zs.first) zi = zs.first;
    if (zi > zs.last) zi = zs.last;
    return zi;
  }

  double get minZoom => 2.0;
  double get maxZoom => (tileSource?.zooms.isEmpty ?? true)
      ? 19.0
      : (tileSource!.zooms.last + 2.0); // allow 2 levels of overzoom

  void setViewport(GeoPoint center, double zoom) {
    _center = center;
    _zoom = zoom.clamp(minZoom, maxZoom).toDouble();
    notifyListeners();
  }

  void centerOn(GeoPoint p, {double? zoom}) {
    setViewport(p, zoom ?? _zoom);
  }

  void zoomBy(double delta, {Offset? focalPx, Size? size}) {
    final target = (_zoom + delta).clamp(minZoom, maxZoom).toDouble();
    if (focalPx != null && size != null) {
      _zoomAroundFocal(target, focalPx, size);
    } else {
      _zoom = target;
      notifyListeners();
    }
  }

  void _zoomAroundFocal(double targetZoom, Offset focalPx, Size size) {
    final worldAtFocal = screenToWorld(focalPx, size);
    _zoom = targetZoom;
    // Keep the focal world point under the finger.
    final halfW = size.width / 2;
    final halfH = size.height / 2;
    final newCenterWorld = Offset(
      worldAtFocal.dx - (focalPx.dx - halfW),
      worldAtFocal.dy - (focalPx.dy - halfH),
    );
    _center = _geoOfWorldPx(newCenterWorld);
    notifyListeners();
  }

  /// Pinch zoom: [startZoom]/[startCenter]/[startFocal] describe the viewport
  /// at gesture start; [scaleFactor]/[currentFocal] the current gesture.
  /// The world point under the start focal stays under the current focal.
  void pinchZoom({
    required double startZoom,
    required GeoPoint startCenter,
    required Offset startFocal,
    required Offset currentFocal,
    required double scaleFactor,
    required Size size,
  }) {
    final target = (startZoom + math.log(scaleFactor) / math.ln2)
        .clamp(minZoom, maxZoom)
        .toDouble();
    final oldScale = math.pow(2.0, startZoom).toDouble();
    final newScale = math.pow(2.0, target).toDouble();
    final centerScreen = Offset(size.width / 2, size.height / 2);
    // World px (start zoom) of the map center and of the start focal point.
    final centerWorld = Offset(
      lonToGlobalX(startCenter.lon, 0, extent: 256) * oldScale,
      latToGlobalY(startCenter.lat, 0, extent: 256) * oldScale,
    );
    final focalWorld = centerWorld + (startFocal - centerScreen);
    // After zoom, the focal world point scales by newScale/oldScale; choose
    // the new center so that point lands under currentFocal.
    final focalWorldNew = focalWorld * (newScale / oldScale);
    final newCenterWorld =
        focalWorldNew + centerScreen - currentFocal;
    _zoom = target;
    _center = GeoPoint(
      globalYToLat(newCenterWorld.dy / newScale, 0, extent: 256),
      globalXToLon(newCenterWorld.dx / newScale, 0, extent: 256),
    );
    followPosition = false;
    notifyListeners();
  }

  /// World pixels at the current zoom: (0,0) = north-west edge of the map,
  /// size = 256 * 2^zoom.
  Offset _worldPxOfGeo(GeoPoint p) {
    final scale = math.pow(2.0, _zoom).toDouble();
    return Offset(
      lonToGlobalX(p.lon, 0, extent: 256) * scale,
      latToGlobalY(p.lat, 0, extent: 256) * scale,
    );
  }

  GeoPoint _geoOfWorldPx(Offset px) {
    final scale = math.pow(2.0, _zoom).toDouble();
    return GeoPoint(
      globalYToLat(px.dy / scale, 0, extent: 256),
      globalXToLon(px.dx / scale, 0, extent: 256),
    );
  }

  /// Geo -> screen for the current viewport & canvas size.
  Offset geoToScreen(GeoPoint p, Size size) {
    final w = _worldPxOfGeo(p);
    final c = _worldPxOfGeo(_center);
    return Offset(
      w.dx - c.dx + size.width / 2,
      w.dy - c.dy + size.height / 2,
    );
  }

  /// Screen -> geo for the current viewport & canvas size.
  GeoPoint screenToGeo(Offset px, Size size) {
    final c = _worldPxOfGeo(_center);
    return _geoOfWorldPx(Offset(
      px.dx - size.width / 2 + c.dx,
      px.dy - size.height / 2 + c.dy,
    ));
  }

  /// World px (at current zoom) under a screen point.
  Offset screenToWorld(Offset px, Size size) {
    final c = _worldPxOfGeo(_center);
    return Offset(
      px.dx - size.width / 2 + c.dx,
      px.dy - size.height / 2 + c.dy,
    );
  }

  void panByScreenDelta(Offset delta) {
    final scale = math.pow(2.0, _zoom).toDouble();
    final c = _worldPxOfGeo(_center);
    _center = _geoOfWorldPx(c - delta);
    assert(scale > 0);
    followPosition = false;
    notifyListeners();
  }

  void setRoute(List<GeoPoint> points) {
    route = points;
    notifyListeners();
  }

  void setMarkers(List<MapMarker> m) {
    markers = m;
    notifyListeners();
  }

  void updatePosition(GeoPoint p, double? heading) {
    position = p;
    headingDeg = heading;
    if (followPosition) _center = p;
    notifyListeners();
  }

  /// Fit the viewport to [bounds] for canvas [size].
  void fitBounds(GeoBounds bounds, Size size, {double paddingPx = 48}) {
    final nw = _worldPxOfZoom1(GeoPoint(bounds.maxLat, bounds.minLon));
    final se = _worldPxOfZoom1(GeoPoint(bounds.minLat, bounds.maxLon));
    final wPx = (se.dx - nw.dx).abs();
    final hPx = (se.dy - nw.dy).abs();
    if (wPx < 1 || hPx < 1) {
      centerOn(bounds.center());
      return;
    }
    final usableW = math.max(32.0, size.width - 2 * paddingPx);
    final usableH = math.max(32.0, size.height - 2 * paddingPx);
    // worldPx at zoom z = worldPx(z1) * 2^(z-1); we computed at zoom 1 below.
    final zx = math.log(usableW / (wPx / 2)) / math.ln2;
    final zy = math.log(usableH / (hPx / 2)) / math.ln2;
    final z = math.min(zx, zy).clamp(minZoom, maxZoom).toDouble();
    setViewport(bounds.center(), z);
  }

  Offset _worldPxOfZoom1(GeoPoint p) => Offset(
        lonToGlobalX(p.lon, 1, extent: 256),
        latToGlobalY(p.lat, 1, extent: 256),
      );
}

/// The map widget: gestures + painter.
class OfflineMap extends StatefulWidget {
  final OfflineMapController controller;
  final void Function(GeoPoint point)? onLongPress;

  /// Shown centered when no tile store is open.
  final String? emptyHint;

  const OfflineMap({
    super.key,
    required this.controller,
    this.onLongPress,
    this.emptyHint,
  });

  @override
  State<OfflineMap> createState() => _OfflineMapState();
}

class _OfflineMapState extends State<OfflineMap> {
  double _startZoom = 0;
  Offset _startFocal = Offset.zero;
  GeoPoint _startCenter = const GeoPoint(0, 0);
  Size _size = Size.zero;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      _size = Size(constraints.maxWidth, constraints.maxHeight);
      final c = widget.controller;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: (d) {
          _startZoom = c.zoom;
          _startFocal = d.localFocalPoint;
          _startCenter = c.center;
        },
        onScaleUpdate: (d) {
          if (d.pointerCount >= 2) {
            c.pinchZoom(
              startZoom: _startZoom,
              startCenter: _startCenter,
              startFocal: _startFocal,
              currentFocal: d.localFocalPoint,
              scaleFactor: d.scale,
              size: _size,
            );
          } else {
            c.panByScreenDelta(d.localFocalPoint - _startFocal);
          }
        },
        onDoubleTapDown: (d) =>
            c.zoomBy(1.0, focalPx: d.localPosition, size: _size),
        onLongPressStart: (d) {
          widget.onLongPress?.call(c.screenToGeo(d.localPosition, _size));
        },
        child: AnimatedBuilder(
          animation: Listenable.merge([
            c,
            if (c.tileSource != null) c.tileSource!,
          ]),
          builder: (context, _) {
            return CustomPaint(
              size: Size.infinite,
              painter: _MapPainter(c),
              child: c.tileSource?.isOpen ?? false
                  ? null
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          widget.emptyHint ??
                              'No offline map bundle active.\nImport one under Settings → Offline Data.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            );
          },
        ),
      );
    });
  }

}

class _MapPainter extends CustomPainter {
  final OfflineMapController c;

  _MapPainter(this.c)
      : super(repaint: Listenable.merge([c, c.tileSource]));

  static const int _maxLabelsPerFrame = 220;

  @override
  void paint(Canvas canvas, Size size) {
    final source = c.tileSource;
    final theme = source?.theme;
    final bg = theme?.backgroundColor ?? 0xFFF8F4F0;
    canvas.drawRect(Offset.zero & size, Paint()..color = Color(bg));

    if (source != null && source.isOpen && theme != null) {
      _paintTiles(canvas, size, source);
    }
    _paintRoute(canvas, size);
    _paintMarkers(canvas, size);
    _paintPosition(canvas, size);
  }

  void _paintTiles(Canvas canvas, Size size, MapTileSource source) {
    final zi = c.tileZoom;
    final scale = math.pow(2.0, c.zoom - zi).toDouble();
    final n = tileCount(zi);

    // Visible world-px rect at zoom zi (tile pixel space).
    final topLeftWorld = c.screenToWorld(Offset.zero, size);
    final bottomRightWorld =
        c.screenToWorld(Offset(size.width, size.height), size);
    final worldPerZiPx = 1.0 / scale; // zi px per current-zoom px
    int tileIndex(double worldPx) => math.max(
        0, math.min(n - 1, ((worldPx * worldPerZiPx) / 256).floor()));
    final x0 = tileIndex(topLeftWorld.dx);
    final y0 = tileIndex(topLeftWorld.dy);
    final x1 = tileIndex(bottomRightWorld.dx);
    final y1 = tileIndex(bottomRightWorld.dy);

    var labels = 0;
    final labelQueue = <void Function()>[];
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        final id = TileId(zi, x, y);
        final cmds = source.commandsFor(id);
        if (cmds == null) continue;
        // Screen offset of this tile's (0,0).
        final tileWorldAtZoom = Offset(x * 256.0 * scale, y * 256.0 * scale);
        final centerWorld = c.screenToWorld(
            Offset(size.width / 2, size.height / 2), size);
        final origin = Offset(
          tileWorldAtZoom.dx - centerWorld.dx + size.width / 2,
          tileWorldAtZoom.dy - centerWorld.dy + size.height / 2,
        );
        for (final cmd in cmds) {
          switch (cmd.kind) {
            case DrawKind.polygon:
              final path = _pathFor(cmd.paths, origin, scale);
              if (path == null) break;
              if (cmd.fill != null) {
                canvas.drawPath(
                    path,
                    Paint()
                      ..style = PaintingStyle.fill
                      ..color = Color(cmd.fill!));
              }
              if (cmd.color != 0x00000000 && cmd.width > 0) {
                canvas.drawPath(
                    path,
                    Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = math.max(0.4, cmd.width * scale)
                      ..color = Color(cmd.color));
              }
            case DrawKind.polyline:
              final path = _pathFor(cmd.paths, origin, scale);
              if (path == null) break;
              canvas.drawPath(
                  path,
                  Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeWidth = math.max(0.4, cmd.width * scale)
                    ..strokeCap = StrokeCap.round
                    ..strokeJoin = StrokeJoin.round
                    ..color = Color(cmd.color));
            case DrawKind.text:
              if (labels >= _maxLabelsPerFrame) break;
              final label = cmd.label;
              if (label == null || label.isEmpty) break;
              labels++;
              final lx = origin.dx + (cmd.labelX ?? 0) * scale;
              final ly = origin.dy + (cmd.labelY ?? 0) * scale;
              final fontSize =
                  math.max(7.0, (cmd.textSize ?? 10) * math.min(1.4, scale));
              // Halo via stacked painters (cheap, readable).
              labelQueue.add(() {
                textPainter.text = TextSpan(
                  text: label,
                  style: TextStyle(
                    fontSize: fontSize,
                    foreground: Paint()
                      ..style = PaintingStyle.stroke
                      ..strokeWidth = 2.5
                      ..color = Color(source.theme.backgroundColor),
                  ),
                );
                textPainter.layout(maxWidth: 240);
                final dx = lx - textPainter.width / 2;
                final dy = ly - textPainter.height / 2;
                if (dx < -40 || dy < -20) return;
                if (dx > size.width + 40 || dy > size.height + 20) return;
                textPainter.paint(canvas, Offset(dx, dy));
                textPainter.text = TextSpan(
                  text: label,
                  style: TextStyle(
                      fontSize: fontSize, color: Color(cmd.color)),
                );
                textPainter.layout(maxWidth: 240);
                textPainter.paint(canvas, Offset(dx, dy));
              });
          }
        }
      }
    }
    for (final draw in labelQueue) {
      draw();
    }
  }

  Path? _pathFor(List<List<double>> paths, Offset origin, double scale) {
    if (paths.isEmpty) return null;
    final path = Path()..fillType = PathFillType.evenOdd;
    var any = false;
    for (final flat in paths) {
      if (flat.length < 4) continue;
      any = true;
      path.moveTo(origin.dx + flat[0] * scale, origin.dy + flat[1] * scale);
      for (var i = 2; i + 1 < flat.length; i += 2) {
        path.lineTo(origin.dx + flat[i] * scale, origin.dy + flat[i + 1] * scale);
      }
      path.close();
    }
    return any ? path : null;
  }

  void _paintRoute(Canvas canvas, Size size) {
    final pts = c.route;
    if (pts.length < 2) return;
    final screen = <Offset>[
      for (final p in pts) c.geoToScreen(p, size),
    ];
    final path = Path()..moveTo(screen[0].dx, screen[0].dy);
    for (var i = 1; i < screen.length; i++) {
      path.lineTo(screen[i].dx, screen[i].dy);
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xD9FFFFFF));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4.5
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = const Color(0xFF1B6AC9));
  }

  void _paintMarkers(Canvas canvas, Size size) {
    for (final m in c.markers) {
      final o = c.geoToScreen(m.point, size);
      if (o.dx < -30 || o.dy < -30 || o.dx > size.width + 30 || o.dy > size.height + 30) {
        continue;
      }
      final color = switch (m.kind) {
        MapMarkerKind.start => const Color(0xFF2E9E44),
        MapMarkerKind.end => const Color(0xFFC62828),
        MapMarkerKind.via => const Color(0xFFF9A825),
      };
      final text = switch (m.kind) {
        MapMarkerKind.start => 'A',
        MapMarkerKind.end => 'B',
        MapMarkerKind.via => '${m.label}',
      };
      // Teardrop: circle + stem.
      final stem = Path()
        ..moveTo(o.dx - 5, o.dy - 6)
        ..lineTo(o.dx + 5, o.dy - 6)
        ..lineTo(o.dx, o.dy + 8)
        ..close();
      canvas.drawPath(stem, Paint()..color = color);
      canvas.drawCircle(Offset(o.dx, o.dy - 12), 10, Paint()..color = color);
      canvas.drawCircle(
          Offset(o.dx, o.dy - 12),
          10,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = Colors.white);
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
              color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(o.dx - tp.width / 2, o.dy - 12 - tp.height / 2));
    }
  }

  void _paintPosition(Canvas canvas, Size size) {
    final p = c.position;
    if (p == null) return;
    final o = c.geoToScreen(p, size);
    // Heading cone.
    final heading = c.headingDeg;
    if (heading != null && heading.isFinite) {
      final rad = heading * math.pi / 180.0;
      final dir = Offset(math.sin(rad), -math.cos(rad));
      final left = Offset(
          math.sin(rad - 0.5) * 30, -math.cos(rad - 0.5) * 30);
      final right = Offset(
          math.sin(rad + 0.5) * 30, -math.cos(rad + 0.5) * 30);
      final cone = Path()
        ..moveTo(o.dx + dir.dx * 8, o.dy + dir.dy * 8)
        ..lineTo(o.dx + left.dx, o.dy + left.dy)
        ..lineTo(o.dx + right.dx, o.dy + right.dy)
        ..close();
      canvas.drawPath(
          cone, Paint()..color = const Color(0x551976D2));
    }
    canvas.drawCircle(o, 9, Paint()..color = const Color(0xFF1976D2));
    canvas.drawCircle(
        o,
        9,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant _MapPainter oldDelegate) => true;
}
