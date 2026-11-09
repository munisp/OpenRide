/// Merge several `tiles.mbf` stores into one (SPEC §4.2).
///
/// Building vector tiles for a large region can exceed available memory
/// (the tile builder holds all parsed features in RAM). The workaround is
/// split-and-merge: build tiles for N vertical bbox slices separately
/// (`bin/build_bundle_bbox.dart --split N`), then merge the per-slice
/// `.mbf` files here. The merged store is byte-level identical in layout
/// to a directly built one: index sorted by (z,x,y), blobs concatenated.
///
/// Overlapping slice boundaries can produce the same tile id in two
/// inputs; the LAST input containing a tile id wins (MbfWriter.replace
/// semantics).
library mbf_merge;

import 'package:maps_core/maps_core.dart';

/// Merges the MBF stores at [inPaths] into [outPath]; returns the number
/// of tiles in the merged store.
int mergeMbf(String outPath, List<String> inPaths) {
  final writer = MbfWriter(outPath);
  for (final path in inPaths) {
    final reader = MbfReader(path);
    try {
      for (final id in reader.tileIds) {
        final blob = reader.getTile(id);
        if (blob != null) writer.putTile(id, blob);
      }
    } finally {
      reader.close();
    }
  }
  writer.finish();
  return writer.tileCount;
}
