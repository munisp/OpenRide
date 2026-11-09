/// Bounding-box pre-filter for bundle building (SPEC §3.5).
///
/// Streaming a full country extract (e.g. Nigeria, ~800 MB PBF) through
/// [readOsmPbf] materializes millions of nodes/ways that a regional bundle
/// does not need. [extractBbox] streams the PBF with the existing reader:
///
///  - pass 1 collects the ids of nodes inside the bbox (and remembers which
///    of those are named POI nodes);
///  - pass 2 keeps ways having at least one in-bbox node (with ALL their
///    referenced nodes, so clipped ways stay whole) and turn restrictions
///    whose from/to ways both survive;
///  - pass 3 materializes the nodes referenced by kept ways plus the named
///    in-bbox POI nodes.
///
/// The resulting [OsmData] feeds the standard bundle build
/// (`buildBundleFromData`), so routing, tiles and the geocoder behave exactly
/// as for a full extract, just restricted to the region.
library bbox_extract;

import 'dart:io';

import 'package:router_engine/router_engine.dart';

/// Geographic bounding box in degrees.
class BBox {
  final double minLat;
  final double minLon;
  final double maxLat;
  final double maxLon;

  const BBox(this.minLat, this.minLon, this.maxLat, this.maxLon);

  bool contains(double lat, double lon) =>
      lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;

  @override
  String toString() => 'BBox($minLat,$minLon,$maxLat,$maxLon)';
}

/// Extracts the subset of [pbfPath] relevant for [bbox]; see library docs.
Future<OsmData> extractBbox(String pbfPath, BBox bbox,
    {void Function(String msg)? log}) async {
  void say(String m) {
    if (log != null) log(m);
  }

  if (!File(pbfPath).existsSync()) {
    throw FileSystemException('input .osm.pbf not found', pbfPath);
  }

  // --- pass 1: in-bbox node ids (+ which of them are named POIs) --------------
  final inBbox = <int>{};
  final namedPoi = <int>{};
  var scannedNodes = 0;
  await streamOsmPbf(
    pbfPath,
    OsmVisitor(
      onNode: (n) {
        scannedNodes++;
        if (bbox.contains(n.lat, n.lon)) {
          inBbox.add(n.id);
          if (n.tags.containsKey('name')) namedPoi.add(n.id);
        }
      },
    ),
  );
  say('pass 1: scanned $scannedNodes nodes, ${inBbox.length} in bbox '
      '(${namedPoi.length} named POIs)');

  // --- pass 2: ways touching the bbox ------------------------------------------
  final ways = <int, OsmWay>{};
  final neededNodeIds = <int>{};
  final pendingRestrictions = <TurnRestriction>[];
  var scannedWays = 0;
  await streamOsmPbf(
    pbfPath,
    OsmVisitor(
      onWay: (w) {
        scannedWays++;
        if (w.nodeRefs.any(inBbox.contains)) {
          ways[w.id] = w;
          neededNodeIds.addAll(w.nodeRefs); // clipped ways stay whole
        }
      },
      onRestriction: pendingRestrictions.add,
    ),
  );
  say('pass 2: scanned $scannedWays ways, kept ${ways.length}');

  // Turn restrictions survive only when both endpoint ways survived.
  final restrictions = <TurnRestriction>[
    for (final r in pendingRestrictions)
      if (ways.containsKey(r.fromWay) && ways.containsKey(r.toWay)) r,
  ];

  // --- pass 3: materialize the nodes the kept ways and POIs need ---------------
  neededNodeIds.addAll(namedPoi);
  final nodes = <int, OsmNode>{};
  await streamOsmPbf(
    pbfPath,
    OsmVisitor(
      onNode: (n) {
        if (neededNodeIds.contains(n.id)) nodes[n.id] = n;
      },
    ),
  );
  say('pass 3: materialized ${nodes.length} of ${neededNodeIds.length} '
      'needed nodes');

  final data = OsmData(nodes: nodes, ways: ways, restrictions: restrictions);
  say('extract: ${data.nodeCount} nodes, ${data.wayCount} ways, '
      '${data.restrictions.length} turn restrictions');
  return data;
}
