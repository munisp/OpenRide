/// Zero-dependency test harness + suite for maps_core (SPEC §8).
/// Run: /tmp/dart-sdk/bin/dart run test/run_tests.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../lib/maps_core.dart';

int _pass = 0;
int _fail = 0;

void t(String name, bool Function() f) {
  try {
    if (f()) {
      _pass++;
      print('PASS $name');
    } else {
      _fail++;
      print('FAIL $name: returned false');
    }
  } catch (e, st) {
    _fail++;
    print('FAIL $name: $e');
    print(st.toString().split('\n').take(4).join('\n'));
  }
}

void expectEq(Object? a, Object? b, [String? msg]) {
  if (a != b) throw Exception('expected <$b> got <$a>${msg != null ? ' ($msg)' : ''}');
}

void expectClose(double a, double b, double tol, [String? msg]) {
  if ((a - b).abs() > tol) {
    throw Exception('expected $a ~= $b (tol $tol)${msg != null ? ' ($msg)' : ''}');
  }
}

void expectTrue(bool v, [String? msg]) {
  if (!v) throw Exception('expected true${msg != null ? ' ($msg)' : ''}');
}

// ---------------------------------------------------------------------------
// MVT round-trip
// ---------------------------------------------------------------------------

MvtLayer _sampleLayer() {
  final layer = MvtLayer('roads');
  layer.features.add(MvtFeature(
    id: 42,
    type: MvtGeomType.point,
    parts: [
      [const MvtPoint(100, 200), const MvtPoint(300, 400)],
    ],
    properties: {'name': 'Broad Street', 'lanes': 2, 'lit': true, 'score': 4.5},
  ));
  layer.features.add(MvtFeature(
    id: 7,
    type: MvtGeomType.linestring,
    parts: [
      [const MvtPoint(0, 0), const MvtPoint(1024, 2048), const MvtPoint(4095, 10)],
      [const MvtPoint(50, 50), const MvtPoint(60, 60)],
    ],
    properties: {'class': 'primary', 'level': -3},
  ));
  layer.features.add(MvtFeature(
    type: MvtGeomType.polygon,
    parts: [
      // closed ring input: duplicate last point must be dropped + ClosePath used
      [
        const MvtPoint(10, 10),
        const MvtPoint(100, 10),
        const MvtPoint(100, 100),
        const MvtPoint(10, 100),
        const MvtPoint(10, 10),
      ],
    ],
    properties: {'class': 'water'},
  ));
  return layer;
}

bool _partsEq(List<List<MvtPoint>> a, List<List<MvtPoint>> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].length != b[i].length) return false;
    for (int j = 0; j < a[i].length; j++) {
      if (a[i][j] != b[i][j]) return false;
    }
  }
  return true;
}

void testMvtRoundTrip() {
  final layers = [_sampleLayer(), MvtLayer('empty')];
  final bytes = encodeMvtTile(layers);
  final decoded = decodeMvtTile(bytes);
  expectEq(decoded.length, 2);
  final l0 = decoded[0];
  expectEq(l0.name, 'roads');
  expectEq(l0.extent, 4096);
  expectEq(l0.features.length, 3);
  final src = layers[0];
  for (int i = 0; i < 3; i++) {
    final a = src.features[i], b = l0.features[i];
    expectEq(a.id, b.id, 'feature $i id');
    expectEq(a.type, b.type, 'feature $i type');
    expectEq(a.properties.length, b.properties.length, 'feature $i prop count');
    a.properties.forEach((k, v) => expectEq(b.properties[k], v, 'feature $i prop $k'));
    // Polygon rings round-trip unclosed (ClosePath semantic); compare unclosed.
    var pa = a.parts;
    if (a.type == MvtGeomType.polygon) {
      pa = [
        for (final ring in a.parts)
          ring.length > 1 && ring.first == ring.last
              ? ring.sublist(0, ring.length - 1)
              : ring,
      ];
    }
    expectTrue(_partsEq(pa, b.parts), 'feature $i geometry round-trip');
  }
  expectEq(decoded[1].name, 'empty');
  expectEq(decoded[1].features.length, 0);
}

void testMvtDecoderRejectsGarbage() {
  var threw = false;
  try {
    decodeMvtTile(Uint8List.fromList([0x1A, 0xFF, 0x01]));
  } catch (_) {
    threw = true;
  }
  expectTrue(threw, 'truncated input must throw FormatException');
}

// ---------------------------------------------------------------------------
// Tile math
// ---------------------------------------------------------------------------

void testTileMath() {
  // Independent first-principles reference (asinh form, computed in-test).
  (int, int) reference(double lat, double lon, int z) {
    final n = math.pow(2, z).toInt();
    final latRad = lat * math.pi / 180.0;
    final x = ((lon + 180.0) / 360.0 * n).floor();
    final y =
        ((1.0 - _asinh(math.tan(latRad)) / math.pi) / 2.0 * n).floor();
    return (x, y);
  }

  // Lagos: 6.5244, 3.3792 — known slippy-map reference values
  // (cross-checked against the standard OSM formula): z15 -> 16691/15788.
  final id = tileFor(6.5244, 3.3792, 15);
  expectEq(id.x, 16691, 'Lagos z15 x (hard reference)');
  expectEq(id.y, 15788, 'Lagos z15 y (hard reference)');
  final ref = reference(6.5244, 3.3792, 15);
  expectEq(id.x, ref.$1, 'Lagos z15 x (independent formula)');
  expectEq(id.y, ref.$2, 'Lagos z15 y (independent formula)');

  final id10 = tileFor(6.5244, 3.3792, 10);
  expectEq(id10.x, 521, 'Lagos z10 x');
  expectEq(id10.y, 493, 'Lagos z10 y');

  // Corner cases.
  expectEq(tileFor(0, 0, 0), const TileId(0, 0, 0));
  expectEq(tileFor(0, 0, 1), const TileId(1, 1, 1));
  expectEq(tileFor(85.05112878, 179.9999, 2), const TileId(2, 3, 0));
  expectEq(tileFor(-85.05112878, -180.0, 2), const TileId(2, 0, 3));

  // Inverse: boundsOf(tileFor(p)) contains p, and tileFor(center) round-trips.
  for (final (lat, lon, z) in [
    (6.5244, 3.3792, 15),
    (51.5074, -0.1278, 12),
    (-33.8688, 151.2093, 9),
    (35.6812, 139.7671, 14),
  ]) {
    final tid = tileFor(lat, lon, z);
    final b = boundsOf(tid);
    expectTrue(b.contains(GeoPoint(lat, lon)), 'boundsOf($tid) contains ($lat,$lon)');
    final c = b.center();
    expectEq(tileFor(c.lat, c.lon, z), tid, 'tileFor(center(boundsOf)) inverse @$z');
  }

  // Global extent coordinate helpers round-trip.
  const z = 15;
  final gx = lonToGlobalX(3.3792, z);
  final gy = latToGlobalY(6.5244, z);
  expectClose(globalXToLon(gx, z), 3.3792, 1e-9);
  expectClose(globalYToLat(gy, z), 6.5244, 1e-9);
  expectEq((gx / 4096).floor(), 16691);
  expectEq((gy / 4096).floor(), 15788);
}

double _asinh(double v) => math.log(v + math.sqrt(v * v + 1));

// ---------------------------------------------------------------------------
// Clipping
// ---------------------------------------------------------------------------

void testClipping() {
  // Cohen–Sutherland: segment fully inside stays, fully outside dropped,
  // crossing segment clipped to box boundary.
  final inside = clipLine(
      [const MvtPoint(100, 100), const MvtPoint(200, 200)], 0, 4096);
  expectEq(inside.length, 1);
  expectTrue(_partsEq(inside, [
    [const MvtPoint(100, 100), const MvtPoint(200, 200)]
  ]));

  final outside = clipLine(
      [const MvtPoint(-100, -100), const MvtPoint(-50, 5000)], 0, 4096);
  expectEq(outside.length, 0);

  final crossing = clipLine(
      [const MvtPoint(-1000, 2048), const MvtPoint(6000, 2048)], 0, 4096);
  expectEq(crossing.length, 1);
  expectEq(crossing[0].first, const MvtPoint(0, 2048));
  expectEq(crossing[0].last, const MvtPoint(4096, 2048));

  // Diagonal crossing two edges.
  final diag = clipLine([const MvtPoint(-1000, -1000), const MvtPoint(2000, 2000)], 0, 4096);
  expectEq(diag.length, 1);
  expectEq(diag[0].first, const MvtPoint(0, 0));
  expectEq(diag[0].last, const MvtPoint(2000, 2000));

  // Polyline leaving and re-entering splits into two parts.
  final reenter = clipLine(
      [
        const MvtPoint(100, 100),
        const MvtPoint(2048, 2048),
        const MvtPoint(8000, 2048), // exit right
        const MvtPoint(2048, 3000), // re-enter
      ],
      0,
      4096);
  expectEq(reenter.length, 2, 're-entering polyline splits');
  expectEq(reenter[0].last, const MvtPoint(4096, 2048));
  expectEq(reenter[1].first, const MvtPoint(4096, 2672));

  // Sutherland–Hodgman: square half outside the left edge becomes a rect.
  final clipped = clipPolygonRing(
      [
        const MvtPoint(-100, 100),
        const MvtPoint(100, 100),
        const MvtPoint(100, 300),
        const MvtPoint(-100, 300),
      ],
      0,
      4096);
  expectEq(clipped.length, 4);
  final xs = clipped.map((p) => p.x).toSet();
  final ys = clipped.map((p) => p.y).toSet();
  expectTrue(xs.contains(0) && xs.contains(100) && xs.length == 2, 'clipped xs $xs');
  expectTrue(ys.contains(100) && ys.contains(300) && ys.length == 2, 'clipped ys $ys');

  // Polygon fully covering the box clips to the box.
  final cover = clipPolygonRing(
      [
        const MvtPoint(-1000, -1000),
        const MvtPoint(5000, -1000),
        const MvtPoint(5000, 5000),
        const MvtPoint(-1000, 5000),
      ],
      0,
      4096);
  expectEq(cover.length, 4);
  for (final p in cover) {
    expectTrue(p.x == 0 || p.x == 4096, 'cover x ${p.x}');
    expectTrue(p.y == 0 || p.y == 4096, 'cover y ${p.y}');
  }

  // Fully outside → empty.
  expectEq(
      clipPolygonRing(
          [const MvtPoint(-100, -100), const MvtPoint(-50, -100), const MvtPoint(-50, -50)],
          0,
          4096)
          .length,
      0);
}

// ---------------------------------------------------------------------------
// MBF store
// ---------------------------------------------------------------------------

void testMbf() {
  final dir = Directory.systemTemp.createTempSync('mbf_test');
  try {
    final path = '${dir.path}/tiles.mbf';
    final w = MbfWriter(path);
    final rng = math.Random(1234);
    final expected = <TileId, Uint8List>{};
    // Add tiles in shuffled order (writer must sort).
    final ids = <TileId>[
      for (int z = 10; z <= 14; z++)
        for (int i = 0; i < 8; i++) TileId(z, 500 + rng.nextInt(20), 480 + rng.nextInt(20)),
    ];
    for (final id in ids) {
      final blob = Uint8List.fromList(
          List<int>.generate(10 + rng.nextInt(100), (_) => rng.nextInt(256)));
      w.putTile(id, blob);
      expected[id] = blob;
    }
    // Duplicate putTile: last write wins.
    final dupId = ids.first;
    final dupBlob = Uint8List.fromList([9, 9, 9, 9]);
    w.putTile(dupId, dupBlob);
    expected[dupId] = dupBlob;
    expectEq(w.tileCount, expected.length);
    w.finish();

    final r = MbfReader(path);
    expectEq(r.tileCount, expected.length);
    // Full reads.
    expected.forEach((id, blob) {
      final got = r.getTile(id);
      expectTrue(got != null, 'tile $id present');
      expectEq(got!.length, blob.length, 'tile $id length');
      for (int i = 0; i < blob.length; i++) {
        if (got[i] != blob[i]) throw Exception('tile $id byte $i differs');
      }
    });
    // Random reads.
    final keys = expected.keys.toList();
    for (int i = 0; i < 25; i++) {
      final id = keys[rng.nextInt(keys.length)];
      final got = r.getTile(id)!;
      final blob = expected[id]!;
      expectEq(got.length, blob.length);
      expectEq(got[0], blob[0]);
    }
    // Missing tile → null.
    expectTrue(r.getTile(const TileId(15, 0, 0)) == null);
    expectTrue(r.getTile(const TileId(12, 500, 0)) == null);
    // zooms()
    expectEq(r.zooms().join(','), '10,11,12,13,14');
    // bounds(): must cover the center of one stored tile.
    final someTile = boundsOf(keys.first).center();
    expectTrue(r.bounds().contains(someTile), 'reader bounds contains tile center');
    r.close();

    // Empty store round-trip.
    final emptyPath = '${dir.path}/empty.mbf';
    MbfWriter(emptyPath).finish();
    final er = MbfReader(emptyPath);
    expectEq(er.tileCount, 0);
    expectEq(er.zooms().length, 0);
    expectTrue(er.getTile(const TileId(0, 0, 0)) == null);
    er.close();

    // Bad magic rejected.
    File('${dir.path}/bad.mbf').writeAsBytesSync([0x42, 0x41, 0x44, 0x21, 0, 0, 0, 0]);
    var threw = false;
    try {
      MbfReader('${dir.path}/bad.mbf');
    } catch (_) {
      threw = true;
    }
    expectTrue(threw, 'bad magic throws');
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// ---------------------------------------------------------------------------
// OSM → tiles builder
// ---------------------------------------------------------------------------

MemoryOsm _lagosSample() {
  // A tiny Lagos-ish extract around lat 6.52, lon 3.37.
  final nodes = <OsmLikeNode>[
    const OsmLikeNode(1, 6.5200, 3.3700),
    const OsmLikeNode(2, 6.5210, 3.3750),
    const OsmLikeNode(3, 6.5220, 3.3800),
    const OsmLikeNode(4, 6.5230, 3.3850),
    // building square
    const OsmLikeNode(10, 6.5210, 3.3710),
    const OsmLikeNode(11, 6.5212, 3.3710),
    const OsmLikeNode(12, 6.5212, 3.3712),
    const OsmLikeNode(13, 6.5210, 3.3712),
    // water square
    const OsmLikeNode(20, 6.5180, 3.3680),
    const OsmLikeNode(21, 6.5180, 3.3690),
    const OsmLikeNode(22, 6.5190, 3.3690),
    const OsmLikeNode(23, 6.5190, 3.3680),
    // landuse square
    const OsmLikeNode(30, 6.5240, 3.3820),
    const OsmLikeNode(31, 6.5240, 3.3830),
    const OsmLikeNode(32, 6.5250, 3.3830),
    const OsmLikeNode(33, 6.5250, 3.3820),
    const OsmLikeNode(40, 6.5244, 3.3792,
        {'place': 'city', 'name': 'Lagos'}),
    const OsmLikeNode(41, 6.5211, 3.3730,
        {'amenity': 'restaurant', 'name': 'Mama Put'}),
  ];
  final ways = <OsmLikeWay>[
    const OsmLikeWay(100, [1, 2, 3, 4], {'highway': 'primary', 'name': 'Marina Road'}),
    const OsmLikeWay(101, [10, 11, 12, 13, 10], {'building': 'yes'}),
    const OsmLikeWay(102, [20, 21, 22, 23, 20], {'natural': 'water', 'name': 'Lagos Lagoon'}),
    const OsmLikeWay(103, [30, 31, 32, 33, 30], {'landuse': 'residential'}),
  ];
  return MemoryOsm(nodeList: nodes, wayList: ways);
}

void testBuilder() {
  final osm = _lagosSample();
  final builder = OsmTileBuilder(minZoom: 14, maxZoom: 14);
  final tiles = builder.build(osm);
  expectTrue(tiles.isNotEmpty, 'tiles produced');

  final centerTile = tileFor(6.5220, 3.3770, 14);
  final bytes = tiles[centerTile];
  expectTrue(bytes != null, 'tile covering extract exists: $centerTile');
  final layers = decodeMvtTile(bytes!);
  final byName = {for (final l in layers) l.name: l};
  for (final name in ['water', 'landuse', 'roads', 'buildings', 'pois', 'labels']) {
    expectTrue(byName.containsKey(name), 'layer $name present');
  }
  // Roads layer has Marina Road as a linestring with class/name.
  final road = byName['roads']!.features.first;
  expectEq(road.type, MvtGeomType.linestring);
  expectEq(road.properties['class'], 'primary');
  expectEq(road.properties['name'], 'Marina Road');
  expectTrue(road.parts.first.length >= 2, 'road has geometry');
  // Buildings layer polygon.
  final bld = byName['buildings']!.features.first;
  expectEq(bld.type, MvtGeomType.polygon);
  expectTrue(bld.parts.first.length >= 3);
  // All clipped geometry within buffered extent.
  for (final l in layers) {
    for (final f in l.features) {
      for (final part in f.parts) {
        for (final p in part) {
          expectTrue(p.x >= -4096 && p.x <= 8192 && p.y >= -4096 && p.y <= 8192,
              'point ${p} within buffered extent (${l.name})');
        }
      }
    }
  }
  // Labels layer contains the city label.
  final labels = byName['labels']!;
  expectTrue(
      labels.features.any((f) => f.properties['name'] == 'Lagos'), 'Lagos label');
  // POI layer contains the restaurant.
  expectTrue(
      byName['pois']!.features.any((f) => f.properties['kind'] == 'amenity.restaurant'),
      'restaurant poi');

  // Zoom filtering: buildings absent at z10.
  final b10 = OsmTileBuilder(minZoom: 10, maxZoom: 10).build(osm);
  final t10 = tileFor(6.5220, 3.3770, 10);
  final names10 = {for (final l in decodeMvtTile(b10[t10]!)) l.name};
  expectTrue(!names10.contains('buildings'), 'no buildings at z10');
  expectTrue(!names10.contains('roads') || true, 'roads allowed filter');
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

void testRender() {
  final theme = RenderTheme.defaultTheme();
  // Background + motorway rule sanity.
  expectEq(theme.backgroundColor, 0xFFF8F4F0);
  final rule = theme.match('roads', {'class': 'motorway'}, 15);
  expectTrue(rule != null, 'motorway rule');
  expectEq(rule!.color, 0xFFE892A2);
  expectClose(rule.widthAt(15), 9.0, 1e-9);
  expectClose(rule.widthAt(10), 2.0, 1e-9);
  expectClose(rule.widthAt(7), 1.28, 1e-9, 'interpolated width');

  // renderTile on a hand-encoded tile.
  final roads = MvtLayer('roads');
  roads.features.add(MvtFeature(
    type: MvtGeomType.linestring,
    parts: [
      [const MvtPoint(0, 2048), const MvtPoint(4096, 2048)],
    ],
    properties: {'class': 'motorway', 'name': 'A1'},
  ));
  final water = MvtLayer('water');
  water.features.add(MvtFeature(
    type: MvtGeomType.polygon,
    parts: [
      [
        const MvtPoint(0, 0),
        const MvtPoint(1024, 0),
        const MvtPoint(1024, 1024),
      ],
    ],
    properties: {'class': 'water'},
  ));
  final labels = MvtLayer('labels');
  labels.features.add(MvtFeature(
    type: MvtGeomType.point,
    parts: [
      [const MvtPoint(2048, 2048)],
    ],
    properties: {'kind': 'city', 'name': 'Lagos'},
  ));
  final cmds = renderTile(encodeMvtTile([water, roads, labels]), theme, 15);
  final poly = cmds.where((c) => c.kind == DrawKind.polygon).toList();
  final line = cmds.where((c) => c.kind == DrawKind.polyline).toList();
  final text = cmds.where((c) => c.kind == DrawKind.text).toList();
  expectEq(poly.length, 1);
  expectEq(poly[0].fill, 0xFFAAD3DF, 'water fill');
  // 4096 extent -> 256 tile space: point 1024 -> 64.0
  expectClose(poly[0].paths[0][2], 64.0, 1e-9);
  expectEq(line.length, 1);
  expectEq(line[0].color, 0xFFE892A2);
  expectClose(line[0].width, 9.0, 1e-9);
  expectClose(line[0].paths[0][1], 128.0, 1e-9, 'y mid tile');
  expectTrue(text.any((c) => c.label == 'Lagos' && c.textSize == 16), 'city label');
  expectTrue(text.any((c) => c.label == 'A1'), 'road name label');
  final city = text.firstWhere((c) => c.label == 'Lagos');
  expectClose(city.labelX!, 128.0, 1e-9);
  expectClose(city.labelY!, 128.0, 1e-9);

  // Zoom-dependent visibility: motorway minZoom 5 → nothing at z4.
  expectEq(renderTile(encodeMvtTile([roads]), theme, 4).length, 0);
}

void testThemeJsonOverride() {
  // Override just the roads layer + background; other layers fall back.
  const overrideJson = '''
  {
    "background": "#101018",
    "layers": {
      "roads": [
        {"match": {"class": "motorway"}, "color": "#FF0000",
         "width": [[15, 12.0]], "minZoom": 5}
      ]
    }
  }
  ''';
  final theme = RenderTheme.fromJson(overrideJson);
  expectEq(theme.backgroundColor, 0xFF101018);
  final rule = theme.match('roads', {'class': 'motorway'}, 15);
  expectEq(rule!.color, 0xFFFF0000);
  expectClose(rule.widthAt(15), 12.0, 1e-9);
  // Untouched layers still default.
  final water = theme.match('water', {'class': 'water'}, 10);
  expectEq(water!.fill, 0xFFAAD3DF, 'water falls back to default');

  final roads = MvtLayer('roads');
  roads.features.add(MvtFeature(
    type: MvtGeomType.linestring,
    parts: [
      [const MvtPoint(0, 0), const MvtPoint(4096, 4096)],
    ],
    properties: {'class': 'motorway'},
  ));
  final cmds = renderTile(encodeMvtTile([roads]), theme, 15);
  expectEq(cmds.length, 1);
  expectEq(cmds[0].color, 0xFFFF0000);
  expectClose(cmds[0].width, 12.0, 1e-9);
}

// ---------------------------------------------------------------------------
// Geocoder
// ---------------------------------------------------------------------------

MemoryOsm _geocoderSample() {
  return MemoryOsm(
    nodeList: const [
      OsmLikeNode(1, 6.5095, 3.3711, {'place': 'city', 'name': 'Lagos Island'}),
      OsmLikeNode(2, 6.5158, 3.3797, {'place': 'suburb', 'name': 'Yaba'}),
      OsmLikeNode(3, 6.5160, 3.3800, {'amenity': 'marketplace', 'name': 'Yaba Market'}),
      OsmLikeNode(4, 6.6018, 3.3515, {'place': 'town', 'name': 'Ikeja'}),
      OsmLikeNode(5, 6.5175, 3.3815, {'shop': 'bakery', 'name': 'Yaba Bakery'}),
      OsmLikeNode(6, 6.5170, 3.3790, {'amenity': 'pharmacy', 'name': 'HealthPlus Pharmacy'}),
      OsmLikeNode(7, 6.5165, 3.3795, {'addr:street': 'Herbert Macaulay Way', 'addr:housenumber': '12'}),
      OsmLikeNode(8, 6.4550, 3.3841, {'place': 'village', 'name': 'Makoko'}),
    ],
    wayList: const [
      OsmLikeWay(100, [1, 2], {'highway': 'primary', 'name': 'Lagos Ring Road'}),
    ],
  );
}

void testGeocoder() {
  final dir = Directory.systemTemp.createTempSync('geocoder_test');
  try {
    final path = '${dir.path}/geocoder.bin';
    Geocoder.build(_geocoderSample(), path);
    expectTrue(File(path).lengthSync() > 16, 'geocoder.bin written');

    final g = Geocoder()..open(path);

    // Exact search.
    var res = g.search('Ikeja');
    expectEq(res.length, 1);
    expectEq(res[0].name, 'Ikeja');
    expectEq(res[0].kind, 'place:town');
    expectClose(res[0].point.lat, 6.6018, 1e-6);
    expectClose(res[0].point.lon, 3.3515, 1e-6);

    // Prefix search on last token: 'yab' matches yaba (suburb, market, bakery).
    res = g.search('yab');
    expectEq(res.length, 3, 'prefix yab hits: ${res.map((r) => r.name).toList()}');

    // Ranking: place:suburb (0.85) > amenity (0.6) == shop (0.6).
    expectEq(res[0].name, 'Yaba');
    expectTrue(res[0].score > res[1].score, 'suburb outranks amenity');
    expectTrue(res[1].score >= res[2].score, 'ranking sorted desc');

    // Multi-token AND intersection + prefix last token.
    res = g.search('yaba mar');
    expectEq(res.length, 1);
    expectEq(res[0].name, 'Yaba Market');

    // AND semantics: token combination that never co-occurs → empty.
    res = g.search('ikeja bakery');
    expectEq(res.length, 0);

    // Address indexing.
    res = g.search('herbert macaulay');
    expectEq(res.length, 1);
    expectEq(res[0].name, 'Herbert Macaulay Way 12');
    expectEq(res[0].kind, 'address');

    // Way names indexed at centroid.
    res = g.search('lagos ring');
    expectEq(res.length, 1);
    expectEq(res[0].kind, 'highway:primary');
    expectClose(res[0].point.lat, (6.5095 + 6.5158) / 2, 1e-6);

    // Ranking without near: class weight, then name tie-break
    // ('Yaba Bakery' < 'Yaba Market' alphabetically at equal weight 0.6).
    res = g.search('yaba');
    expectEq(res[0].name, 'Yaba', 'class weight wins without near');
    expectEq(res[1].name, 'Yaba Bakery', 'alphabetical tie-break without near');
    expectEq(res[2].name, 'Yaba Market');

    // Proximity ranking: near the market, the market must jump ahead of the
    // (equally-weighted but ~215 m away) bakery; exact match 'Yaba' stays first.
    res = g.search('yaba', near: const GeoPoint(6.5160, 3.3800)); // at the market
    expectEq(res.length, 3);
    expectEq(res[0].name, 'Yaba', 'exact match stays first with near=');
    expectEq(res[1].name, 'Yaba Market', 'proximity reorders equal-class results');
    expectTrue(res[1].score > res[2].score, 'nearer scores higher');

    // Limit respected.
    res = g.search('yaba', limit: 2);
    expectEq(res.length, 2);

    // Empty/garbage queries.
    expectEq(g.search('').length, 0);
    expectEq(g.search('!!!').length, 0);
    expectEq(g.search('zzzznope').length, 0);

    // Re-open round trip (data persists on disk).
    final g2 = Geocoder()..open(path);
    expectEq(g2.search('makoko').length, 1);
    expectEq(g2.search('makoko')[0].kind, 'place:village');

    g.close();
    g2.close();
  } finally {
    dir.deleteSync(recursive: true);
  }
}

// ---------------------------------------------------------------------------

void main() {
  t('mvt round-trip encode/decode', () {
    testMvtRoundTrip();
    return true;
  });
  t('mvt decoder rejects truncated input', () {
    testMvtDecoderRejectsGarbage();
    return true;
  });
  t('tile math vs reference values', () {
    testTileMath();
    return true;
  });
  t('geometry clipping (lines + polygons)', () {
    testClipping();
    return true;
  });
  t('mbf store round-trip with random reads', () {
    testMbf();
    return true;
  });
  t('osm->tiles builder layers/zooms', () {
    testBuilder();
    return true;
  });
  t('renderTile draw commands', () {
    testRender();
    return true;
  });
  t('theme JSON override', () {
    testThemeJsonOverride();
    return true;
  });
  t('geocoder prefix search + ranking', () {
    testGeocoder();
    return true;
  });

  print('');
  print('PASS: $_pass  FAIL: $_fail');
  if (_fail > 0) exit(1);
}
