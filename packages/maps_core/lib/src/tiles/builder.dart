/// OSM → vector tiles builder (SPEC §4.1).
/// Consumes an [OsmLike] node/way stream and produces MVT tiles at zooms
/// 0..15 with layers: water, landuse, roads, buildings, pois, labels.
/// Geometry is clipped per tile (buffered) so neighbouring tiles render
/// seamlessly.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../osm_like.dart';
import 'clip.dart';
import 'mvt.dart';
import 'tile_math.dart';

/// Layer names in canonical draw order.
const List<String> kTileLayerOrder = [
  'water',
  'landuse',
  'roads',
  'buildings',
  'pois',
  'labels',
];

class OsmTileBuilder {
  final int minZoom;
  final int maxZoom;
  final int extent;

  /// Clip buffer around each tile, in extent units.
  final int buffer;

  OsmTileBuilder({
    this.minZoom = 0,
    this.maxZoom = 15,
    this.extent = mvtDefaultExtent,
  }) : buffer = extent ~/ 32;

  // --- classification -------------------------------------------------------

  static const _waterwayPoly = {
    'riverbank',
    'dock',
    'canal',
    'basin',
    'reservoir',
  };

  bool _isWater(Map<String, String> t) =>
      t['natural'] == 'water' ||
      t['natural'] == 'bay' ||
      t['natural'] == 'coastline' ||
      _waterwayPoly.contains(t['waterway']) ||
      t['landuse'] == 'reservoir' ||
      t['landuse'] == 'basin' ||
      t.containsKey('water');

  bool _isLanduse(Map<String, String> t) =>
      t.containsKey('landuse') ||
      t['leisure'] == 'park' ||
      t['leisure'] == 'garden' ||
      t['leisure'] == 'pitch' ||
      t['leisure'] == 'playground' ||
      t['natural'] == 'wood' ||
      t['natural'] == 'scrub' ||
      t['natural'] == 'grassland' ||
      t['natural'] == 'beach' ||
      t['natural'] == 'wetland';

  bool _isRoad(Map<String, String> t) => t.containsKey('highway');

  bool _isBuilding(Map<String, String> t) => t.containsKey('building');

  String? _poiKind(Map<String, String> t) {
    for (final k in const ['amenity', 'shop', 'tourism']) {
      final v = t[k];
      if (v != null) return '$k.$v';
    }
    return null;
  }

  int _roadMinZoom(String cls) {
    switch (cls) {
      case 'motorway':
      case 'trunk':
      case 'motorway_link':
      case 'trunk_link':
        return 5;
      case 'primary':
      case 'primary_link':
        return 8;
      case 'secondary':
      case 'secondary_link':
        return 10;
      case 'tertiary':
      case 'tertiary_link':
        return 12;
      case 'residential':
      case 'unclassified':
      case 'living_street':
      case 'pedestrian':
        return 13;
      default: // service, track, path, cycleway, footway, ...
        return 14;
    }
  }

  int _labelMinZoom(String place) {
    switch (place) {
      case 'city':
        return 3;
      case 'town':
        return 8;
      case 'village':
        return 10;
      case 'suburb':
      case 'hamlet':
      case 'neighbourhood':
        return 12;
      default:
        return 12;
    }
  }

  // --- build -----------------------------------------------------------------

  /// Build all tiles covering the data, zooms [minZoom]..[maxZoom].
  /// Returns a sparse map: only non-empty tiles are present.
  Map<TileId, Uint8List> build(OsmLike src) {
    final layers = buildLayers(src);
    final out = <TileId, Uint8List>{};
    layers.forEach((id, byName) {
      final ordered = <MvtLayer>[
        for (final name in kTileLayerOrder)
          if (byName.containsKey(name)) byName[name]!,
      ];
      out[id] = encodeMvtTile(ordered);
    });
    return out;
  }

  /// Intermediate form: tile id → layer name → layer. Exposed for tests/tools.
  Map<TileId, Map<String, MvtLayer>> buildLayers(OsmLike src) {
    final nodesById = <int, OsmLikeNode>{};
    for (final n in src.nodes) {
      nodesById[n.id] = n;
    }
    final tiles = <TileId, Map<String, MvtLayer>>{};

    MvtLayer layerFor(TileId id, String name) {
      final byName = tiles.putIfAbsent(id, () => <String, MvtLayer>{});
      return byName.putIfAbsent(name, () => MvtLayer(name, extent: extent));
    }

    void addFeature(String layerName, int featureMinZoom, List<_LatLon> geom,
        MvtGeomType type, Map<String, Object?> props, int featureId) {
      if (geom.isEmpty) return;
      for (int z = math.max(minZoom, featureMinZoom); z <= maxZoom; z++) {
        // Global extent-unit coordinates at this zoom.
        final gx = List<double>.filled(geom.length, 0);
        final gy = List<double>.filled(geom.length, 0);
        double minX = double.infinity, maxX = -double.infinity;
        double minY = double.infinity, maxY = -double.infinity;
        for (int i = 0; i < geom.length; i++) {
          gx[i] = lonToGlobalX(geom[i].lon, z, extent: extent);
          gy[i] = latToGlobalY(geom[i].lat, z, extent: extent);
          if (gx[i] < minX) minX = gx[i];
          if (gx[i] > maxX) maxX = gx[i];
          if (gy[i] < minY) minY = gy[i];
          if (gy[i] > maxY) maxY = gy[i];
        }
        final n = tileCount(z);
        var tx0 = (minX / extent).floor() - 1;
        var tx1 = (maxX / extent).floor() + 1;
        var ty0 = (minY / extent).floor() - 1;
        var ty1 = (maxY / extent).floor() + 1;
        tx0 = tx0.clamp(0, n - 1);
        tx1 = tx1.clamp(0, n - 1);
        ty0 = ty0.clamp(0, n - 1);
        ty1 = ty1.clamp(0, n - 1);
        final lo = -buffer;
        final hi = extent + buffer;
        for (int tx = tx0; tx <= tx1; tx++) {
          for (int ty = ty0; ty <= ty1; ty++) {
            final ox = tx * extent, oy = ty * extent;
            final local = [
              for (int i = 0; i < geom.length; i++)
                MvtPoint((gx[i] - ox).round(), (gy[i] - oy).round())
            ];
            List<List<MvtPoint>> clipped;
            switch (type) {
              case MvtGeomType.point:
                final pts = clipPoints(local, 0, extent);
                if (pts.isEmpty) continue;
                clipped = [pts];
              case MvtGeomType.linestring:
                clipped = clipLine(local, lo, hi);
                if (clipped.isEmpty) continue;
              case MvtGeomType.polygon:
                clipped = clipPolygon([local], lo, hi);
                if (clipped.isEmpty) continue;
              case MvtGeomType.unknown:
                continue;
            }
            layerFor(TileId(z, tx, ty), layerName).features.add(MvtFeature(
                  id: featureId,
                  type: type,
                  parts: clipped,
                  properties: props,
                ));
          }
        }
      }
    }

    // --- ways ---
    for (final w in src.ways) {
      final pts = <_LatLon>[];
      for (final ref in w.refs) {
        final n = nodesById[ref];
        if (n != null) pts.add(_LatLon(n.lat, n.lon));
      }
      if (pts.length < 2) continue;
      final tags = w.tags;
      final closed = w.isClosed;
      final name = tags['name'];

      if (_isRoad(tags) && tags['area'] != 'yes') {
        final cls = tags['highway']!;
        addFeature('roads', _roadMinZoom(cls), pts, MvtGeomType.linestring, {
          'class': cls,
          if (name != null) 'name': name,
          if (tags['oneway'] == 'yes') 'oneway': 'yes',
        }, w.id);
        if (name != null) {
          final mid = pts[pts.length ~/ 2];
          addFeature('labels', 13, [mid], MvtGeomType.point,
              {'kind': 'road', 'name': name}, w.id);
        }
      } else if (closed && _isWater(tags)) {
        addFeature('water', 0, pts, MvtGeomType.polygon, {
          'class': 'water',
          if (name != null) 'name': name,
        }, w.id);
        if (name != null) {
          addFeature('labels', 10, [_centroid(pts)], MvtGeomType.point,
              {'kind': 'water', 'name': name}, w.id);
        }
      } else if (closed && _isBuilding(tags)) {
        addFeature('buildings', 13, pts, MvtGeomType.polygon, {
          'class': tags['building']!,
          if (name != null) 'name': name,
        }, w.id);
      } else if (closed && _isLanduse(tags)) {
        final cls = tags['landuse'] ??
            tags['leisure'] ??
            tags['natural'] ??
            'landuse';
        addFeature('landuse', 10, pts, MvtGeomType.polygon, {
          'class': cls,
          if (name != null) 'name': name,
        }, w.id);
        if (name != null) {
          addFeature('labels', 12, [_centroid(pts)], MvtGeomType.point,
              {'kind': 'landuse', 'name': name}, w.id);
        }
      }
      final poi = _poiKind(tags);
      if (poi != null && name != null) {
        addFeature('pois', 13, [_centroid(pts)], MvtGeomType.point,
            {'kind': poi, 'name': name}, w.id);
      }
    }

    // --- nodes ---
    for (final n in src.nodes) {
      final tags = n.tags;
      if (tags.isEmpty) continue;
      final name = tags['name'];
      final place = tags['place'];
      if (place != null && name != null) {
        addFeature('labels', _labelMinZoom(place), [_LatLon(n.lat, n.lon)],
            MvtGeomType.point, {'kind': place, 'name': name}, n.id);
      }
      final poi = _poiKind(tags);
      if (poi != null) {
        addFeature('pois', 13, [_LatLon(n.lat, n.lon)], MvtGeomType.point,
            {'kind': poi, if (name != null) 'name': name}, n.id);
      }
    }

    return tiles;
  }

  _LatLon _centroid(List<_LatLon> pts) {
    double la = 0, lo = 0;
    for (final p in pts) {
      la += p.lat;
      lo += p.lon;
    }
    return _LatLon(la / pts.length, lo / pts.length);
  }
}

class _LatLon {
  final double lat, lon;
  const _LatLon(this.lat, this.lon);
}
