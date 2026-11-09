/// Pure-Dart renderer model (SPEC §4.3): decode an MVT tile and produce a
/// styled list of [DrawCommand]s in tile screen space (0..tileSize).
library;

import 'dart:typed_data';

import '../tiles/mvt.dart';
import 'theme.dart';

enum DrawKind { polyline, polygon, text }

class DrawCommand {
  final DrawKind kind;

  /// Polylines/polygons: one path per part, each path flattened
  /// [x0, y0, x1, y1, ...] in tile screen space (0..tileSize).
  /// Polygon paths: exterior ring first, then holes.
  final List<List<double>> paths;

  /// Stroke color (polylines, polygon outlines, text) as ARGB.
  final int color;

  /// Fill color (polygons), null for lines/text.
  final int? fill;

  /// Stroke width in logical pixels.
  final double width;

  /// Text label + anchor (text commands only).
  final String? label;
  final double? labelX, labelY, textSize;

  const DrawCommand._({
    required this.kind,
    this.paths = const [],
    this.color = 0xFF000000,
    this.fill,
    this.width = 1.0,
    this.label,
    this.labelX,
    this.labelY,
    this.textSize,
  });

  factory DrawCommand.polyline(List<List<double>> paths, int color, double width) =>
      DrawCommand._(kind: DrawKind.polyline, paths: paths, color: color, width: width);

  factory DrawCommand.polygon(List<List<double>> paths, int fill, int outline, double width) =>
      DrawCommand._(
          kind: DrawKind.polygon,
          paths: paths,
          color: outline,
          fill: fill,
          width: width);

  factory DrawCommand.text(String label, double x, double y, double size, int color) =>
      DrawCommand._(
          kind: DrawKind.text,
          label: label,
          labelX: x,
          labelY: y,
          textSize: size,
          color: color);

  @override
  String toString() => 'DrawCommand($kind, ${paths.length} paths, '
      '${label != null ? 'label=$label, ' : ''}color=#${color.toRadixString(16)})';
}

/// Decode [mvt] bytes and style them with [theme] at [zoom].
/// Coordinates are scaled from tile extent units to 0..[tileSize].
/// Output is ordered by layer (background layers first) so painters can draw
/// the list in order.
List<DrawCommand> renderTile(Uint8List mvt, RenderTheme theme, int zoom,
    {double tileSize = 256.0}) {
  final layers = decodeMvtTile(mvt);
  final out = <DrawCommand>[];
  for (final layer in layers) {
    final scale = tileSize / layer.extent;
    for (final f in layer.features) {
      final rule = theme.match(layer.name, f.properties, zoom);
      if (rule == null) continue;
      List<List<double>> scaled() => [
            for (final part in f.parts)
              [
                for (final p in part) ...[p.x * scale, p.y * scale],
              ],
          ];
      switch (f.type) {
        case MvtGeomType.polygon:
          if (rule.fill == null && rule.color == null) break;
          out.add(DrawCommand.polygon(
            scaled(),
            rule.fill ?? 0x00000000,
            rule.color ?? 0x00000000,
            rule.widthAt(zoom),
          ));
        case MvtGeomType.linestring:
          if (rule.color == null) break;
          out.add(DrawCommand.polyline(scaled(), rule.color!, rule.widthAt(zoom)));
        case MvtGeomType.point:
        case MvtGeomType.unknown:
          break;
      }
      // Label: any matched feature carrying a name with a rule textSize.
      final name = f.properties['name'];
      if (name != null && rule.textSize != null) {
        double lx = 0, ly = 0;
        if (f.type == MvtGeomType.point && f.parts.isNotEmpty && f.parts.first.isNotEmpty) {
          lx = f.parts.first.first.x * scale;
          ly = f.parts.first.first.y * scale;
        } else if (f.parts.isNotEmpty && f.parts.first.isNotEmpty) {
          final mid = f.parts.first[f.parts.first.length ~/ 2];
          lx = mid.x * scale;
          ly = mid.y * scale;
        } else {
          continue;
        }
        out.add(DrawCommand.text(
            name.toString(), lx, ly, rule.textSize!, rule.textColor ?? 0xFF000000));
      } else if (f.type == MvtGeomType.point &&
          layer.name == 'pois' &&
          rule.color != null) {
        // Unnamed POI: small dot marker.
        for (final part in f.parts) {
          for (final p in part) {
            out.add(DrawCommand.polygon(
              [
                [
                  (p.x - 3) * scale,
                  (p.y - 3) * scale,
                  (p.x + 3) * scale,
                  (p.y - 3) * scale,
                  (p.x + 3) * scale,
                  (p.y + 3) * scale,
                  (p.x - 3) * scale,
                  (p.y + 3) * scale,
                ]
              ],
              rule.color!,
              rule.color!,
              rule.widthAt(zoom),
            ));
          }
        }
      }
    }
  }
  return out;
}
