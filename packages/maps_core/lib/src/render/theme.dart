/// Render theme (SPEC §4.3): colors/widths per layer + class per zoom.
/// JSON-loadable via dart:convert; ships an embedded OSM-carto-ish light
/// default theme that can be overridden (fully or per-layer) from a JSON
/// string.
library;

import 'dart:convert';

/// One styling rule inside a layer. The first rule whose [match] constraints
/// are satisfied by a feature's properties applies.
class StyleRule {
  /// Property constraints. Value '*' matches any present value.
  final Map<String, String> match;
  final int minZoom;

  /// Line color (ARGB) for polylines / polygon outlines.
  final int? color;

  /// Fill color (ARGB) for polygons.
  final int? fill;

  /// Base line width in logical pixels at the reference zoom, or null when
  /// [widthStops] is used.
  final double? width;

  /// Zoom → width stops, e.g. `[[5, 0.5], [15, 8]]`; linearly interpolated.
  final List<List<double>>? widthStops;

  /// Text size in logical pixels when the feature carries a name label.
  final double? textSize;
  final int? textColor;

  const StyleRule({
    this.match = const {},
    this.minZoom = 0,
    this.color,
    this.fill,
    this.width,
    this.widthStops,
    this.textSize,
    this.textColor,
  });

  /// Match values support '|' alternates and '*' (any present value).
  bool matches(Map<String, Object?> props, int zoom) {
    if (zoom < minZoom) return false;
    for (final e in match.entries) {
      final v = props[e.key]?.toString();
      if (v == null) return false;
      final alts = e.value.split('|');
      if (!alts.contains('*') && !alts.contains(v)) return false;
    }
    return true;
  }

  /// Width at [zoom]: linear interpolation across stops (clamped outside),
  /// else the flat [width], else 1.0.
  double widthAt(int zoom) {
    final stops = widthStops;
    if (stops == null || stops.isEmpty) return width ?? 1.0;
    if (zoom <= stops.first[0]) return stops.first[1];
    if (zoom >= stops.last[0]) return stops.last[1];
    for (int i = 0; i + 1 < stops.length; i++) {
      final z0 = stops[i][0], w0 = stops[i][1];
      final z1 = stops[i + 1][0], w1 = stops[i + 1][1];
      if (zoom >= z0 && zoom <= z1) {
        final t = (zoom - z0) / (z1 - z0);
        return w0 + (w1 - w0) * t;
      }
    }
    return stops.last[1];
  }
}

class RenderTheme {
  /// Layer name → rules (evaluated in order, first match wins).
  final Map<String, List<StyleRule>> layers;

  /// Background color (ARGB).
  final int backgroundColor;

  const RenderTheme(this.layers, {this.backgroundColor = 0xFFF8F4F0});

  /// First rule in [layer] matching [props] at [zoom], or null.
  StyleRule? match(String layer, Map<String, Object?> props, int zoom) {
    final rules = layers[layer];
    if (rules == null) return null;
    for (final r in rules) {
      if (r.matches(props, zoom)) return r;
    }
    return null;
  }

  /// Parse a theme from a JSON string. Colors are '#RRGGBB' or '#AARRGGBB'.
  /// Missing sections fall back to the default theme so callers can override
  /// just one layer or the background.
  static RenderTheme fromJson(String json) {
    final m = jsonDecode(json);
    if (m is! Map<String, Object?>) {
      throw const FormatException('theme JSON must be an object');
    }
    return fromMap(m);
  }

  /// Build from a decoded map; layers not present fall back to defaults.
  static RenderTheme fromMap(Map<String, Object?> m) {
    final def = _parseMap(_defaultTheme);
    final bg = m['background'] is String
        ? parseColor(m['background'] as String)
        : def.backgroundColor;
    final layers = Map<String, List<StyleRule>>.from(def.layers);
    final lm = m['layers'];
    if (lm is Map) {
      lm.forEach((k, v) {
        if (v is List) {
          layers[k.toString()] = [
            for (final r in v)
              if (r is Map) _parseRule(r.cast<String, Object?>()),
          ];
        }
      });
    }
    return RenderTheme(layers, backgroundColor: bg);
  }

  /// The embedded default OSM-carto-ish light theme.
  static RenderTheme defaultTheme() => _parseMap(_defaultTheme);

  static RenderTheme _parseMap(Map<String, Object?> m) {
    final layers = <String, List<StyleRule>>{};
    (m['layers'] as Map<String, Object?>).forEach((k, v) {
      layers[k] = [
        for (final r in v as List) _parseRule((r as Map).cast<String, Object?>()),
      ];
    });
    return RenderTheme(layers, backgroundColor: parseColor(m['background'] as String));
  }

  static StyleRule _parseRule(Map<String, Object?> r) {
    List<List<double>>? stops;
    final w = r['width'];
    if (w is List) {
      stops = [
        for (final s in w)
          [(s as List)[0] as num, s[1] as num].map((n) => n.toDouble()).toList(),
      ];
    }
    final match = <String, String>{};
    final mm = r['match'];
    if (mm is Map) {
      mm.forEach((k, v) => match[k.toString()] = v.toString());
    }
    return StyleRule(
      match: match,
      minZoom: (r['minZoom'] as num?)?.toInt() ?? 0,
      color: r['color'] is String ? parseColor(r['color'] as String) : null,
      fill: r['fill'] is String ? parseColor(r['fill'] as String) : null,
      width: w is num ? w.toDouble() : null,
      widthStops: stops,
      textSize: (r['textSize'] as num?)?.toDouble(),
      textColor: r['textColor'] is String ? parseColor(r['textColor'] as String) : null,
    );
  }

  /// '#RRGGBB' or '#AARRGGBB' → ARGB int.
  static int parseColor(String s) {
    var hex = s.startsWith('#') ? s.substring(1) : s;
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) throw FormatException('bad color: $s');
    return int.parse(hex, radix: 16);
  }
}

const Map<String, Object?> _defaultTheme = {
  'background': '#F8F4F0',
  'layers': {
    'water': [
      {'fill': '#AAD3DF', 'color': '#AAD3DF'},
    ],
    'landuse': [
      {
        'match': {'class': 'park|garden|pitch|playground|wood|scrub|grassland'},
        'fill': '#D2E8C2',
        'color': '#D2E8C2',
        'minZoom': 10,
      },
      {
        'match': {'class': '*'},
        'fill': '#E8E4D8',
        'color': '#E8E4D8',
        'minZoom': 10,
      },
    ],
    'roads': [
      {
        'match': {'class': 'motorway'},
        'color': '#E892A2',
        'width': [[5, 0.8], [10, 2.0], [15, 9.0]],
        'minZoom': 5,
        'textSize': 10,
        'textColor': '#333333',
      },
      {
        'match': {'class': 'trunk'},
        'color': '#F9B29C',
        'width': [[5, 0.7], [10, 1.8], [15, 8.0]],
        'minZoom': 5,
        'textSize': 10,
        'textColor': '#333333',
      },
      {
        'match': {'class': 'primary'},
        'color': '#FCD6A4',
        'width': [[8, 1.0], [12, 2.5], [15, 7.0]],
        'minZoom': 8,
        'textSize': 10,
        'textColor': '#333333',
      },
      {
        'match': {'class': 'secondary'},
        'color': '#F7FABC',
        'width': [[10, 1.0], [13, 2.5], [15, 6.0]],
        'minZoom': 10,
        'textSize': 10,
        'textColor': '#333333',
      },
      {
        'match': {'class': 'tertiary'},
        'color': '#FFFFFF',
        'width': [[12, 1.2], [15, 5.0]],
        'minZoom': 12,
        'textSize': 9,
        'textColor': '#444444',
      },
      {
        'match': {'class': '*'},
        'color': '#FFFFFF',
        'width': [[13, 0.8], [15, 4.0]],
        'minZoom': 13,
        'textSize': 9,
        'textColor': '#444444',
      },
    ],
    'buildings': [
      {
        'fill': '#D9D0C9',
        'color': '#C4BBB2',
        'width': 0.5,
        'minZoom': 13,
      },
    ],
    'pois': [
      {
        'match': {'kind': '*'},
        'color': '#734A08',
        'width': 2.0,
        'minZoom': 13,
        'textSize': 9,
        'textColor': '#734A08',
      },
    ],
    'labels': [
      {
        'match': {'kind': 'city'},
        'textSize': 16,
        'textColor': '#222222',
        'minZoom': 3,
      },
      {
        'match': {'kind': 'town'},
        'textSize': 13,
        'textColor': '#222222',
        'minZoom': 8,
      },
      {
        'match': {'kind': 'village'},
        'textSize': 11,
        'textColor': '#333333',
        'minZoom': 10,
      },
      {
        'match': {'kind': 'road'},
        'textSize': 9,
        'textColor': '#555555',
        'minZoom': 13,
      },
      {
        'match': {'kind': '*'},
        'textSize': 10,
        'textColor': '#444444',
        'minZoom': 12,
      },
    ],
  },
};
