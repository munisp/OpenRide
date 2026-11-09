/// OpenRide geocoder-only bundle tool (SPEC §4.4 / §5).
///
///   dart run bin/build_geocoder.dart in.osm.pbf outdir/ minLat minLon maxLat maxLon
///
/// Re-runs the bbox extraction (see `lib/src/bbox_extract.dart`) and builds
/// ONLY `geocoder.bin`. Useful when the full bundle build was interrupted
/// (e.g. OOM in the tile builder) and the geocoder index is still missing.
library build_geocoder;

import 'dart:io';

import 'package:maps_core/maps_core.dart';

import '../lib/src/bbox_extract.dart';
import '../lib/src/bundle_build.dart';

Future<void> main(List<String> args) async {
  if (args.length != 6) {
    stderr.writeln('usage: dart run bin/build_geocoder.dart '
        'in.osm.pbf outdir/ minLat minLon maxLat maxLon');
    exitCode = 2;
    return;
  }
  final bbox = BBox(double.parse(args[2]), double.parse(args[3]),
      double.parse(args[4]), double.parse(args[5]));
  try {
    final data = await extractBbox(args[0], bbox, log: stdout.writeln);
    Directory(args[1]).createSync(recursive: true);
    final sw = Stopwatch()..start();
    Geocoder.build(OsmDataAdapter(data), '${args[1]}/geocoder.bin');
    sw.stop();
    stdout.writeln('geocoder.bin written in ${sw.elapsedMilliseconds} ms');
  } catch (e) {
    stderr.writeln('build_geocoder failed: $e');
    exitCode = 1;
  }
}
