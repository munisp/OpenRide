/// Split tile building for memory-constrained environments (SPEC §4.2).
///
/// The vector tile builder (`OsmTileBuilder`) holds all parsed features of
/// the region in RAM; for a large bbox on a small container this is the
/// step that OOMs (observed: 5.97M-node Lagos bbox on a 4 GB container).
/// [buildTilesSplit] cuts the bbox into [slices] vertical (longitude)
/// slices and builds a separate tile store per slice
/// (`$outDir/tiles.slice$i.mbf`), so peak memory is roughly 1/N of the
/// full-region build. Merge the slices afterwards with
/// `bin/merge_mbf.dart` (see `lib/src/mbf_merge.dart`) into the final
/// `tiles.mbf`.
///
/// Ways crossing a slice boundary are kept whole on both sides
/// (`extractBbox` keeps every way that touches the slice with ALL its
/// nodes), so no geometry is lost mid-way. Each tile is written by exactly
/// ONE slice: the one owning the tile's west edge. That slice's extraction
/// contains every way with a node on its side IN FULL, so owned tiles are
/// byte-identical to a direct full-region build — except tiles at/around
/// a seam, which can miss a way that crosses the seam without any node on
/// the owning side (rare with real OSM road density). Covered by
/// `test/mbf_merge_test.dart`.
library split_tiles;

import 'dart:io';

import 'package:maps_core/maps_core.dart';

import 'bbox_extract.dart';
import 'bundle_build.dart';

/// Builds per-slice tile stores for [bbox] cut into [slices] vertical
/// slices; returns the slice file paths in slice order.
Future<List<String>> buildTilesSplit(
    String pbfPath, BBox bbox, int slices, String outDir,
    {void Function(String msg)? log}) async {
  if (slices < 1) {
    throw ArgumentError.value(slices, 'slices', 'must be >= 1');
  }
  void say(String m) {
    if (log != null) log(m);
  }

  Directory(outDir).createSync(recursive: true);
  final lonStep = (bbox.maxLon - bbox.minLon) / slices;

  /// Slice ownership: tile belongs to the slice containing its west edge.
  /// Each tile is written by exactly one slice, so merged output matches a
  /// direct build except at seams (see library docs).
  int ownerOf(TileId id) {
    var idx =
        ((boundsOf(id).minLon - bbox.minLon) / lonStep).floor();
    return idx.clamp(0, slices - 1);
  }

  final paths = <String>[];
  for (var i = 0; i < slices; i++) {
    final slice = BBox(bbox.minLat, bbox.minLon + i * lonStep, bbox.maxLat,
        i == slices - 1 ? bbox.maxLon : bbox.minLon + (i + 1) * lonStep);
    say('slice ${i + 1}/$slices: $slice');
    final sw = Stopwatch()..start();
    final data = await extractBbox(pbfPath, slice, log: log);
    final tiles = OsmTileBuilder().build(OsmDataAdapter(data));
    final path = '$outDir/tiles.slice$i.mbf';
    final mbf = MbfWriter(path);
    var kept = 0;
    for (final entry in tiles.entries) {
      if (ownerOf(entry.key) == i) {
        mbf.putTile(entry.key, entry.value);
        kept++;
      }
    }
    mbf.finish();
    sw.stop();
    say('slice ${i + 1}/$slices: $kept of ${tiles.length} tiles -> $path '
        '(${sw.elapsedMilliseconds} ms)');
    paths.add(path);
  }
  return paths;
}
