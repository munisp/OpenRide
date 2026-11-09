// Unit coverage for the MBF split-and-merge tooling (SPEC §4.2 / §8):
// mergeMbf combines two stores into one with a sorted (z,x,y) index, all
// entries readable, last input wins on duplicate tile ids; a two-slice
// split build of a tiny synthetic city yields the same tiles as a direct
// single-slice build.
// Spawned as a subprocess by run_tests.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:maps_core/maps_core.dart';
import 'package:router_engine/testing/pbf_writer.dart';
import '../lib/src/bbox_extract.dart';
import '../lib/src/mbf_merge.dart';
import '../lib/src/split_tiles.dart';

void _expect(bool cond, String what) {
  if (!cond) {
    stderr.writeln('assertion failed: $what');
    exit(1);
  }
}

Uint8List _blob(int seed) => Uint8List.fromList(List.generate(32, (i) => (seed + i) & 0xFF));

void _writeMbf(String path, Map<TileId, Uint8List> tiles) {
  final w = MbfWriter(path);
  tiles.forEach(w.putTile);
  w.finish();
}

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('openride_mbfmerge_').path;

  // --- merge of two tiny hand-written stores --------------------------------
  const a1 = TileId(14, 8175, 8011);
  const a2 = TileId(14, 8176, 8011);
  const a3 = TileId(12, 2043, 2002); // sorts before z14 entries
  final bShared = a2; // duplicate across inputs: last input must win
  const b1 = TileId(15, 16352, 16023);
  _writeMbf('$dir/a.mbf', {a1: _blob(1), a2: _blob(2), a3: _blob(3)});
  _writeMbf('$dir/b.mbf', {bShared: _blob(99), b1: _blob(4)});

  final n = mergeMbf('$dir/merged.mbf', ['$dir/a.mbf', '$dir/b.mbf']);
  _expect(n == 4, 'merged store has 4 unique tiles, got $n');
  final r = MbfReader('$dir/merged.mbf');
  _expect(r.tileCount == 4, 'reader sees 4 tiles');
  _expect(_eq(r.getTile(a1), _blob(1)), 'a1 payload readable');
  _expect(_eq(r.getTile(a3), _blob(3)), 'a3 payload readable');
  _expect(_eq(r.getTile(b1), _blob(4)), 'b1 payload readable');
  _expect(_eq(r.getTile(a2), _blob(99)), 'duplicate tile: last input wins');
  // index sorted by (z,x,y): zooms ascending, keys sorted
  final ids = r.tileIds;
  _expect(ids[0] == a3, 'z12 entry sorts before z14 entries');
  _expect(ids[ids.length - 1] == b1, 'z15 entry sorts last');
  _expect(r.getTile(const TileId(14, 1, 1)) == null, 'absent tile -> null');
  r.close();

  // --- split build of a synthetic city --------------------------------------
  // Merge machinery must preserve every tile; tiles AWAY from the slice seam
  // must be byte-identical to a direct build. Tiles straddling the seam (or
  // within the builder's +-1 tile emission margin of it) may legitimately
  // differ: each slice only has its own side's fully-contained features.
  final pbf = '$dir/city.osm.pbf';
  final city = GridCity(6, 6.40, 3.10, 0.01);
  writeOsmPbf(pbf, nodes: city.nodes, ways: city.ways);
  const bbox = BBox(6.39, 3.09, 6.46, 3.16);
  const seamLon = 3.09 + (3.16 - 3.09) / 2; // N=2 slices -> seam at 3.125

  final slicePaths = await buildTilesSplit(pbf, bbox, 2, '$dir/split');
  _expect(slicePaths.length == 2, 'two slice files produced');
  for (final p in slicePaths) {
    _expect(File(p).existsSync(), 'slice file exists: $p');
  }
  mergeMbf('$dir/split-merged.mbf', slicePaths);

  final directPaths = await buildTilesSplit(pbf, bbox, 1, '$dir/direct');
  final split = MbfReader('$dir/split-merged.mbf');
  final direct = MbfReader(directPaths.single);
  _expect(split.tileCount == direct.tileCount,
      'split-merged tile count matches direct build '
      '(${split.tileCount} vs ${direct.tileCount})');
  var identical = 0, seamTiles = 0;
  for (final id in direct.tileIds) {
    final b = boundsOf(id);
    final tileW = b.maxLon - b.minLon;
    final nearSeam =
        b.minLon - tileW < seamLon && b.maxLon + tileW > seamLon;
    if (nearSeam) {
      seamTiles++;
      _expect(split.getTile(id) != null, 'seam tile $id present in merged');
      continue;
    }
    _expect(_eq(split.getTile(id), direct.getTile(id)),
        'non-seam tile $id identical between split and direct build');
    identical++;
  }
  _expect(seamTiles > 0, 'test exercises seam tiles ($seamTiles)');
  split.close();
  direct.close();

  stdout.writeln('mbf_merge_test: OK (merge 4 tiles; split==direct on '
      '$identical non-seam tiles, $seamTiles seam-adjacent tiles present)');
}

bool _eq(Uint8List? a, Uint8List? b) {
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
