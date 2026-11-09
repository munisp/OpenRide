/// OpenRide bundle tool (SPEC §3.5).
///
///   dart run bin/build_bundle.dart in.osm.pbf outdir/
///
/// Produces an offline bundle in outdir/:
///   graph.bin     — routing graph (SPEC §3.2 binary v1)
///   geocoder.bin  — offline geocoder index (SPEC §4.4 / §5)
///   tiles.mbf     — vector tile store (SPEC §4.2)
///   meta.json     — {bounds, generatedAt, sourceBytes}
///
/// The implementation lives in `lib/src/bundle_build.dart` so the Flutter
/// app can reuse it through the package barrel (relative URIs cannot escape
/// `lib/` under `package:` resolution); it is re-exported here for tests.
library build_bundle;

import 'dart:io';

import '../lib/src/bundle_build.dart';

export '../lib/src/bundle_build.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run bin/build_bundle.dart in.osm.pbf outdir/');
    exitCode = 2;
    return;
  }
  try {
    await buildBundle(args[0], args[1], log: stdout.writeln);
  } catch (e) {
    stderr.writeln('build_bundle failed: $e');
    exitCode = 1;
  }
}
