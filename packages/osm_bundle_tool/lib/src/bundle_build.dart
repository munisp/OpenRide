/// OpenRide bundle build logic (SPEC §3.5), shared by the CLI
/// (`bin/build_bundle.dart`) and the Flutter app's offline-data import.
///
/// Produces an offline bundle in an output directory:
///   graph.bin     — routing graph (SPEC §3.2 binary v1)
///   geocoder.bin  — offline geocoder index (SPEC §4.4 / §5)
///   tiles.mbf     — vector tile store (SPEC §4.2)
///   meta.json     — {bounds, generatedAt, sourceBytes}
library bundle_build;

import 'dart:convert';
import 'dart:io';

import 'package:maps_core/maps_core.dart';
import 'package:router_engine/router_engine.dart';

/// Adapts parsed [OsmData] to maps_core's [OsmLike] stream interface.
class OsmDataAdapter implements OsmLike {
  final OsmData data;
  OsmDataAdapter(this.data);

  @override
  Iterable<OsmLikeNode> get nodes => data.nodes.values
      .map((n) => OsmLikeNode(n.id, n.lat, n.lon, n.tags));

  @override
  Iterable<OsmLikeWay> get ways =>
      data.ways.values.map((w) => OsmLikeWay(w.id, w.nodeRefs, w.tags));
}

/// Builds the whole bundle; returns a summary map (also written to
/// meta.json). Used by the CLI, by tests, and by the app (via isolates).
Future<Map<String, Object>> buildBundle(String pbfPath, String outDir,
    {void Function(String msg)? log}) async {
  final srcFile = File(pbfPath);
  if (!srcFile.existsSync()) {
    throw FileSystemException('input .osm.pbf not found', pbfPath);
  }
  final sourceBytes = srcFile.lengthSync();

  void say(String m) {
    if (log != null) log(m);
  }

  say('reading $pbfPath (${sourceBytes} bytes) ...');
  final osm = await readOsmPbf(pbfPath);
  return buildBundleFromData(osm, outDir, sourceBytes: sourceBytes, log: log);
}

/// Builds the whole bundle from an already-parsed (possibly pre-filtered,
/// e.g. by `bbox_extract.dart`) [OsmData]. [sourceBytes] is recorded in
/// meta.json; when null the input element count is recorded instead.
Future<Map<String, Object>> buildBundleFromData(OsmData osm, String outDir,
    {int? sourceBytes, void Function(String msg)? log}) async {
  void say(String m) {
    if (log != null) log(m);
  }

  sourceBytes ??= osm.nodeCount + osm.wayCount;
  Directory(outDir).createSync(recursive: true);
  say('parsed ${osm.nodeCount} nodes, ${osm.wayCount} ways, '
      '${osm.restrictions.length} turn restrictions');

  // --- graph.bin -------------------------------------------------------------
  final graph = RoutingGraph.build(osm, isRoutable: defaultRoutableFilter);
  graph.serializeTo('$outDir/graph.bin');
  say('graph.bin: ${graph.nodeCount} nodes, ${graph.edgeCount} edges');

  // --- tiles.mbf + geocoder.bin (maps_core writers) ---------------------------
  final osmLike = OsmDataAdapter(osm);

  final builder = OsmTileBuilder();
  final tiles = builder.build(osmLike);
  final mbf = MbfWriter('$outDir/tiles.mbf');
  for (final entry in tiles.entries) {
    mbf.putTile(entry.key, entry.value);
  }
  mbf.finish();
  say('tiles.mbf: ${tiles.length} tiles');

  Geocoder.build(osmLike, '$outDir/geocoder.bin');
  say('geocoder.bin written');

  // --- meta.json ---------------------------------------------------------------
  var bounds = const GeoBounds(0, 0, 0, 0);
  if (osm.nodes.isNotEmpty) {
    bounds = GeoBounds.of(osm.nodes.values
        .map((n) => GeoPoint(n.lat, n.lon)));
  }
  final meta = <String, Object>{
    'bounds': {
      'minLat': bounds.minLat,
      'minLon': bounds.minLon,
      'maxLat': bounds.maxLat,
      'maxLon': bounds.maxLon,
    },
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'sourceBytes': sourceBytes,
  };
  File('$outDir/meta.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(meta));
  say('meta.json written');
  return meta;
}
