/// Tile source for the offline map: opens the active bundle's `tiles.mbf`
/// via maps_core's MbfReader and decodes MVT → DrawCommand lists with a
/// RenderTheme, cached per tile.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:maps_core/maps_core.dart';

/// Compact dark override for the map (falls back to the default theme for
/// any layer not listed here — see RenderTheme.fromMap).
const String _darkThemeJson = '''
{
  "background": "#15181C",
  "layers": {
    "water": [
      {"fill": "#1B2E3C", "color": "#1B2E3C"}
    ],
    "landuse": [
      {"match": {"class": "park|garden|pitch|playground|wood|scrub|grassland"},
       "fill": "#1E2B1E", "color": "#1E2B1E", "minZoom": 10},
      {"match": {"class": "*"}, "fill": "#23272C", "color": "#23272C", "minZoom": 10}
    ],
    "roads": [
      {"match": {"class": "motorway"}, "color": "#7E4A55",
       "width": [[5, 0.8], [10, 2.0], [15, 9.0]], "minZoom": 5,
       "textSize": 10, "textColor": "#CCCCCC"},
      {"match": {"class": "trunk"}, "color": "#7A5A44",
       "width": [[5, 0.7], [10, 1.8], [15, 8.0]], "minZoom": 5,
       "textSize": 10, "textColor": "#CCCCCC"},
      {"match": {"class": "primary"}, "color": "#77683F",
       "width": [[8, 1.0], [12, 2.5], [15, 7.0]], "minZoom": 8,
       "textSize": 10, "textColor": "#CCCCCC"},
      {"match": {"class": "secondary"}, "color": "#6E6E50",
       "width": [[10, 1.0], [13, 2.5], [15, 6.0]], "minZoom": 10,
       "textSize": 10, "textColor": "#BBBBBB"},
      {"match": {"class": "tertiary"}, "color": "#5A5E63",
       "width": [[12, 1.2], [15, 5.0]], "minZoom": 12,
       "textSize": 9, "textColor": "#BBBBBB"},
      {"match": {"class": "*"}, "color": "#4A4E54",
       "width": [[13, 0.8], [15, 4.0]], "minZoom": 13,
       "textSize": 9, "textColor": "#BBBBBB"}
    ],
    "buildings": [
      {"fill": "#2B3036", "color": "#3A4046", "width": 0.5, "minZoom": 13}
    ],
    "pois": [
      {"match": {"kind": "*"}, "color": "#C9A24B", "width": 2.0, "minZoom": 13,
       "textSize": 9, "textColor": "#C9A24B"}
    ],
    "labels": [
      {"match": {"kind": "city"}, "textSize": 16, "textColor": "#E8E8E8", "minZoom": 3},
      {"match": {"kind": "town"}, "textSize": 13, "textColor": "#DDDDDD", "minZoom": 8},
      {"match": {"kind": "village"}, "textSize": 11, "textColor": "#CCCCCC", "minZoom": 10},
      {"match": {"kind": "road"}, "textSize": 9, "textColor": "#AAAAAA", "minZoom": 13},
      {"match": {"kind": "*"}, "textSize": 10, "textColor": "#BBBBBB", "minZoom": 12}
    ]
  }
}
''';

class MapTileSource extends ChangeNotifier {
  MbfReader? _reader;
  String? _path;

  /// zoom → cached decoded tiles; null value = tile absent from store.
  final Map<TileId, List<DrawCommand>?> _cache = {};

  RenderTheme _theme = RenderTheme.defaultTheme();
  final RenderTheme _lightTheme = RenderTheme.defaultTheme();
  late final RenderTheme _darkTheme = RenderTheme.fromJson(_darkThemeJson);

  bool _dark = false;

  bool get isOpen => _reader != null;
  RenderTheme get theme => _theme;

  /// Zoom levels present in the store (empty when closed).
  List<int> get zooms => _reader?.zooms() ?? const [];

  /// Geographic coverage of the store (null when closed/empty).
  GeoBounds? get coverage => isOpen ? _reader!.bounds() : null;

  int get tileCount => _reader?.tileCount ?? 0;

  void open(String mbfPath) {
    close();
    _reader = MbfReader(mbfPath);
    _path = mbfPath;
    notifyListeners();
  }

  void close() {
    _reader?.close();
    _reader = null;
    _path = null;
    _cache.clear();
    notifyListeners();
  }

  void setDark(bool dark) {
    if (_dark == dark) return;
    _dark = dark;
    _theme = dark ? _darkTheme : _lightTheme;
    _cache.clear();
    notifyListeners();
  }

  bool get dark => _dark;

  /// Decoded draw list for [id], or null when the tile is not in the store.
  /// [zoom] is the integer zoom of the tile (theme widths depend on it).
  List<DrawCommand>? commandsFor(TileId id) {
    final cached = _cache[id];
    if (cached != null || _cache.containsKey(id)) return cached;
    final reader = _reader;
    if (reader == null) return null;
    final Uint8List? mvt;
    try {
      mvt = reader.getTile(id);
    } on FormatException {
      _cache[id] = null;
      return null;
    }
    final cmds = mvt == null ? null : renderTile(mvt, _theme, id.z);
    // Simple bounded cache: drop everything when it grows too large; tiles
    // are cheap to re-decode.
    if (_cache.length > 512) _cache.clear();
    _cache[id] = cmds;
    return cmds;
  }
}
