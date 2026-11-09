/// OpenRide maps_core (SPEC §4): vector tiles (MVT), offline tile store
/// (.mbf), renderer model, offline geocoder. Pure Dart, zero dependencies.
library maps_core;

export 'package:shared/shared.dart' show GeoPoint, GeoBounds;

export 'src/osm_like.dart';
export 'src/tiles/mvt.dart';
export 'src/tiles/tile_math.dart';
export 'src/tiles/clip.dart';
export 'src/tiles/builder.dart';
export 'src/tilestore/mbf.dart';
export 'src/render/theme.dart';
export 'src/render/render.dart';
export 'src/geocoder/geocoder.dart';
