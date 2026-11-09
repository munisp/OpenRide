/// OpenRide MBF merge tool (SPEC §4.2).
///
///   dart run bin/merge_mbf.dart out.mbf in1.mbf in2.mbf [...]
///
/// Merges several `tiles.mbf` stores (e.g. the `tiles.slice$i.mbf` files
/// produced by `bin/build_bundle_bbox.dart --split N`) into a single store
/// with a sorted (z,x,y) index, byte-layout identical to a directly built
/// one. On overlapping tile ids the last input wins.
library merge_mbf;

import 'dart:io';

import '../lib/src/mbf_merge.dart';

void main(List<String> args) {
  if (args.length < 3) {
    stderr.writeln(
        'usage: dart run bin/merge_mbf.dart out.mbf in1.mbf in2.mbf [...]');
    exitCode = 2;
    return;
  }
  try {
    final sw = Stopwatch()..start();
    final n = mergeMbf(args[0], args.sublist(1));
    sw.stop();
    stdout.writeln('merged ${args.length - 1} stores -> ${args[0]} '
        '($n tiles, ${sw.elapsedMilliseconds} ms)');
  } catch (e) {
    stderr.writeln('merge_mbf failed: $e');
    exitCode = 1;
  }
}
