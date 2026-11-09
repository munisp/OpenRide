/// OpenRide bbox bundle tool (SPEC §3.5).
///
///   dart run bin/build_bundle_bbox.dart in.osm.pbf outdir/ minLat minLon maxLat maxLon [--split N]
///
/// Pre-filters a large extract to the given bounding box (see
/// `lib/src/bbox_extract.dart`) and then runs the standard bundle build,
/// producing the same output files as `bin/build_bundle.dart`:
///   graph.bin     — routing graph (SPEC §3.2 binary v1)
///   geocoder.bin  — offline geocoder index (SPEC §4.4 / §5)
///   tiles.mbf     — vector tile store (SPEC §4.2)
///   meta.json     — {bounds, generatedAt, sourceBytes}
///
/// With `--split N` (N = 1, 2, 4, ... vertical longitude slices) ONLY the
/// vector tiles are built, as N separate stores `outdir/tiles.slice$i.mbf`
/// — the memory-friendly path for large regions on small containers.
/// Merge them afterwards:
///   dart run bin/merge_mbf.dart outdir/tiles.mbf outdir/tiles.slice*.mbf
library build_bundle_bbox;

import 'dart:io';

import '../lib/src/bbox_extract.dart';
import '../lib/src/bundle_build.dart';
import '../lib/src/split_tiles.dart';

export '../lib/src/bbox_extract.dart';

Future<void> main(List<String> args) async {
  if (args.length != 6 && args.length != 8) {
    stderr.writeln('usage: dart run bin/build_bundle_bbox.dart '
        'in.osm.pbf outdir/ minLat minLon maxLat maxLon [--split N]');
    exitCode = 2;
    return;
  }
  var split = 0;
  if (args.length == 8) {
    if (args[6] != '--split' || (split = int.tryParse(args[7]) ?? 0) < 1) {
      stderr.writeln('invalid --split N (N must be an integer >= 1)');
      exitCode = 2;
      return;
    }
  }
  final nums = <double>[];
  for (final a in args.sublist(2, 6)) {
    final v = double.tryParse(a);
    if (v == null) {
      stderr.writeln('invalid coordinate: $a');
      exitCode = 2;
      return;
    }
    nums.add(v);
  }
  final bbox = BBox(nums[0], nums[1], nums[2], nums[3]);
  if (bbox.minLat > bbox.maxLat || bbox.minLon > bbox.maxLon) {
    stderr.writeln('invalid bbox: min must not exceed max ($bbox)');
    exitCode = 2;
    return;
  }
  try {
    if (split > 0) {
      // Memory-friendly tiles-only path: one store per vertical slice.
      final paths =
          await buildTilesSplit(args[0], bbox, split, args[1], log: stdout.writeln);
      stdout.writeln('split build done; merge with: dart run '
          'bin/merge_mbf.dart ${args[1]}/tiles.mbf ${paths.join(' ')}');
      return;
    }
    final sourceBytes = File(args[0]).lengthSync();
    final data =
        await extractBbox(args[0], bbox, log: stdout.writeln);
    await buildBundleFromData(data, args[1],
        sourceBytes: sourceBytes, log: stdout.writeln);
  } catch (e) {
    stderr.writeln('build_bundle_bbox failed: $e');
    exitCode = 1;
  }
}
