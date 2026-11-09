# SPEC — Offline Route Planner & Navigator ("OpenRide")

Flutter app (iOS/Android). **Fully offline**: routing, maps, place search all run on-device from OpenStreetMap data. Ride recording with sensors, GPX/FIT/TCX export. **No account, no backend, no analytics.** BRouter routing engine ported to Dart.

## 1. Repository layout

```
project/
├── SPEC.md                      (this file, copied from /mnt/agents/output/routeplanner/SPEC.md)
├── README.md
├── packages/
│   ├── shared/                  owner: AGENT-A  — geo primitives used by all packages
│   ├── router_engine/           owner: AGENT-A  — BRouter port: OSM PBF parse, graph, routing, profiles
│   ├── maps_core/               owner: AGENT-B  — vector tiles, offline tile store, renderer model, geocoder
│   ├── nav_engine/              owner: AGENT-C  — turn-by-turn navigation state machine
│   ├── ride_core/               owner: AGENT-D  — recording, sensors model, GPX/TCX/FIT export, storage
│   └── osm_bundle_tool/         owner: AGENT-A  — CLI: .osm.pbf -> offline bundle (graph + tiles + geocoder)
└── app/                         owner: AGENT-E  — Flutter application shell
```

**Hard rules**
- All `packages/*` are **pure Dart, ZERO external pub dependencies** (only `dart:` libraries). This makes them testable with the bare Dart SDK: `dart run test/run_tests.dart` inside each package (each package ships its own zero-dependency test runner — see §8).
- No mocks, no stubs, no TODOs, no placeholder returns. Every function implemented for real.
- `app/` MAY use pub packages (flutter, geolocator, flutter_blue_plus, path_provider, permission_handler, sensors_plus, wakelock_plus) but talks to packages only through the interfaces below.
- All coordinates WGS-84 degrees internally; distances meters; speeds m/s; time `DateTime` UTC + epoch ms.

## 2. packages/shared (owner A)

```dart
// lib/shared.dart
class GeoPoint { final double lat, lon; final double? ele; const GeoPoint(this.lat, this.lon, {this.ele});
  double distanceTo(GeoPoint o);          // haversine, meters
  double bearingTo(GeoPoint o);           // initial bearing, degrees 0..360
  GeoPoint destination(double bearingDeg, double distM); }
class GeoBounds { final double minLat, minLon, maxLat, maxLon; /* contains(), center(), expand() */ }
enum Profile { trekking, fastbike, roadbike, mtb, carFast, carEco, foot }
class LatLngBounds + polyline helpers:
List<GeoPoint> decodePolyline6(String s);  String encodePolyline6(List<GeoPoint> pts); // OSRM-style precision-6
double pathLengthM(List<GeoPoint> pts);
List<double> cumulativeDistancesM(List<GeoPoint> pts);
// turn angle between consecutive segments, signed degrees (-180..180, + = right)
double signedTurnAngle(GeoPoint a, GeoPoint b, GeoPoint c);
```

## 3. packages/router_engine (owner A) — the BRouter port

### 3.1 OSM PBF reader (`lib/src/pbf/`)
Real .osm.pbf parser: BlobHeader/Blob framing (magic-length-prefixed protobuf), zlib/raw inflate via `dart:io` ZLibDecoder, hand-rolled protobuf wire reader (varint/fixed32/fixed64/length-delimited), PrimitiveBlock decoding: string table, granularity/offset, dense nodes (delta-coded), ways, relations. **Skip relations except turn-restriction tags** (`restriction=no_left_turn` etc. with from/via/to refs).
```dart
class OsmData { Map<int, OsmNode> nodes; Map<int, OsmWay> ways; List<TurnRestriction> restrictions; }
class OsmNode { int id; double lat, lon; Map<String,String> tags; }
class OsmWay  { int id; List<int> nodeRefs; Map<String,String> tags; }
class TurnRestriction { int fromWay, viaNode, toWay; RestrictionType type; }
Future<OsmData> readOsmPbf(String path);            // streaming, two-pass capable
```

### 3.2 Routing graph (`lib/src/graph/`)
```dart
class RoutingGraph {
  int nodeCount, edgeCount;
  // compressed adjacency: arrays; each directed edge: targetNode, distM, costFactor(per profile computed lazily), wayId
  static RoutingGraph build(OsmData osm, {required bool Function(OsmWay) isRoutable});
  List<int> edgesOf(int node);                  // edge ids
  int edgeTarget(int edge); double edgeDistM(int edge); int edgeWay(int edge);
  int nearestNode(double lat, double lon);      // grid index, O(1)-ish
  void serializeTo(String path); static RoutingGraph loadFrom(String path); // binary format v1
}
```
Routable filter per profile semantics: highways motorway..path, cycleway, track; oneway handling (-1/reversible), access/bicycle/foot/motor_vehicle tags, junction=roundabout.

### 3.3 Profile cost engine — BRouter semantics (`lib/src/profile/`)
BRouter computes edge cost = dist * factor where factor derives from profile params over way tags + elevation. Port the real parameter model:
```dart
class CostProfile {           // defaults replicate brouter trekking.brf gist
  Map<String,double> highwayCost;   // motorway..path
  Map<String,double> surfaceCost;   // asphalt, gravel, ground, sand...
  double turnCostBase, turnCostSlopeExp;  // BRouter turncost model
  double uphillSlopeExp, downhillSlopeExp, downhillCutoff, uphillCutoff;
  bool considerTurnRestrictions;
  double initialCost; }
double edgeCostFactor(CostProfile p, OsmWayTags tags);   // multiplicative model like BRouter's waycost
double turnCost(CostProfile p, double signedAngleDeg);
double elevationCostFactor(CostProfile p, double grade); // grade = rise/run
```

### 3.4 Router (`lib/router_engine.dart` — public API)
```dart
class RouteRequest { GeoPoint from, to; List<GeoPoint> via; Profile profile; bool elevationFromSrtm; }
class RouteResult {
  List<GeoPoint> points; double distM; double timeS; double ascendM, descendM;
  List<RouteLeg> legs; }                       // legs split at via points
class RouteLeg { List<GeoPoint> points; double distM, timeS; }
abstract class RouterEngine {
  Future<void> loadGraph(String bundlePath);   // loads graph.bin + elevation tiles if present
  RouteResult route(RouteRequest req);         // throws NoRouteException
}
RouterEngine createRouterEngine();
```
Algorithm: **bidirectional A\*** with haversine heuristic, turn costs + turn restrictions applied via edge-pair expansion, elevation from SRTM HGT tiles in bundle (`srtm/` dir, 1-arcsec .hgt, bilinear interp). Time model: BRouter-style — base speed per highway class degraded by cost factor. Must route a 50 km cross-city case in < 2 s on a desktop-class CPU.

### 3.5 packages/osm_bundle_tool (owner A)
CLI `dart run bin/build_bundle.dart in.osm.pbf outdir/` producing:
`graph.bin` (3.2 format), `geocoder.bin` (spec §5 index), `tiles.mbf` (§4 tile store), `meta.json` {bounds, generatedAt, sourceBytes}. Reuses maps_core's index/tilestore writers via path dependency.

## 4. packages/maps_core (owner B)

### 4.1 Vector tiles
Minimal real MVT encoder/decoder (protobuf varints, layer/feature/keys/values, zigzag deltas, commands MoveTo/LineTo/ClosePath, extent 4096). OSM→tile builder at zooms 0–15 with layers: water, landuse, roads, buildings, pois, labels. Geometry clipping per tile (Sutherland–Hodgman for polygons, Cohen–Sutherland for lines). Web-mercator tile math:
```dart
class TileId { int z, x, y; }
TileId tileFor(double lat, double lon, int z);  GeoBounds boundsOf(TileId);
```
### 4.2 Tile store (`lib/src/tilestore/`)
Single-file store `tiles.mbf`: header `MBF1`, z/x/y→(offset,len) B-tree-ish sorted index + blob area; writer + random-access reader via `RandomAccessFile`.
```dart
class MbfWriter { void putTile(TileId id, Uint8List mvt); void finish(); }
class MbfReader { Uint8List? getTile(TileId id); List<int> zooms(); GeoBounds bounds(); }
```
### 4.3 Renderer model (`lib/src/render/`)
Pure-Dart: decode tile → styled draw list:
```dart
class RenderTheme { /* colors/widths per layer+class per zoom, JSON-loadable, default OSM-carto-ish light theme */ }
class DrawCommand { /* polyline/polygon/text with screen coords in tile space, color, width, label */ }
List<DrawCommand> renderTile(Uint8List mvt, RenderTheme theme, int zoom);
```
### 4.4 Offline geocoder (`lib/src/geocoder/`)
From OSM: named nodes/ways (name, addr:*, amenity/shop/tourism). Forward index: token→posting list (delta+varint), entry: kind, lat/lon(int32 e7), name string-pool ref. Intersection search with prefix last-token, ranked by class weight + distance to optional center.
```dart
class Geocoder { static void build(OsmLike source, String outPath);   // OsmLike = the minimal node/way stream iface in maps_core
  void open(String path);
  List<GeoSearchResult> search(String query, {GeoPoint? near, int limit = 20}); }
class GeoSearchResult { String name; String kind; GeoPoint point; double score; }
```

## 5. packages/nav_engine (owner C) — pure Dart

```dart
class Maneuver { ManeuverType type; double lat, lon; double distFromStartM; String instruction; // English text
  String? roadName; int? exitNumber; }
enum ManeuverType { depart, turnLeft, turnRight, slightLeft, slightRight, sharpLeft, sharpRight,
  uturn, straight, roundaboutEnter, roundaboutExit, arrive }
List<Maneuver> buildManeuvers(RouteResult route, {List<String>? wayNames});  // from geometry+graph way names
class NavState { double distToNextManeuverM; Maneuver? next; double offRouteDistM; bool rerouting; double etaS; double remainingM; }
class Navigator {
  Navigator(RouteResult route, RouterEngine engine, Profile profile);
  NavState update(GeoPoint pos, double speedMps, double headingDeg);  // snap-to-route (sliding window),
                                             // maneuver advance (30m trigger), off-route if >25m for >5s -> auto reroute
  RouteResult? currentRoute; }
```
Off-route reroute: calls engine.route(from: pos, to: destination). Voice strings: "In 200 meters, turn right onto X".

## 6. packages/ride_core (owner D) — pure Dart

```dart
class TrackPoint { DateTime t; double lat, lon; double? ele, speed, hr, cad, power, temp; }
class Ride { String id; DateTime started; List<TrackPoint> points; Map<String,num> stats; }
class RideRecorder {  // state machine: idle/recording/paused; Kalman-smoothed GPS (constant-velocity model)
  void start(); void pause(); void resume(); Ride stop();
  void addGps(DateTime t, double lat, double lon, {double? accuracy, double? speed});
  void addSensor(SensorKind k, double v); }   // hr/cadence/power/temp/baro-ele
enum SensorKind { heartRate, cadence, speed, power, temperature, barometricElevation }
// Export — all real format writers:
String toGpx(Ride r);                 // GPX 1.1 + TrackPointExtension (hr/cad/power)
String toTcx(Ride r);                 // Garmin TCX v2 schema-valid
Uint8List toFit(Ride r);              // FIT binary: header(14B)+CRC, def+data msgs, record(20), session(18),
                                      // lap(19), activity(34) with local mesg types; CRC-16 per FIT spec
// Storage: append-only binary log per ride + catalog index; directory layout <root>/rides/<id>.trk
class RideStore { Future<Ride> save(Ride r); List<RideSummary> list(); Future<Ride> load(String id); void delete(String id); }
```

## 7. app/ (owner E) — Flutter shell

Screens: **Map/Planner** (offline map via CustomPainter over maps_core DrawCommands, tap=set start/end/via, profile picker, route polyline overlay, maneuver list), **Navigate** (next-maneuver banner, voice via flutter TTS optional behind flag, live position), **Record** (start/pause/stop, live stats, sensor list), **History** (ride list, detail with stats + export share via share_plus), **Settings/Data** (bundle manager: import .osm.pbf via file_picker → run osm_bundle_tool logic in isolate; theme). Platform: Android manifest (ACCESS_FINE_LOCATION, FOREGROUND_SERVICE_LOCATION, BLUETOOTH_CONNECT/SCAN, POST_NOTIFICATIONS), iOS Info.plist (NSLocationAlwaysAndWhenInUse, UIBackgroundModes location+bluetooth-central, NSBluetoothAlways). Adapters implement small interfaces wrapping geolocator/flutter_blue_plus/sensors_plus. No account, no network calls at runtime.

## 8. Testing protocol (every package)

No pub.dev dependency is guaranteed available → each package ships `test/run_tests.dart`:
```dart
// tiny harness: void t(String name, bool Function() f) / expectEq/expectClose; exit(1) on failure; prints PASS count
```
Run: `/tmp/dart-sdk/bin/dart run test/run_tests.dart` (agent must ensure dart exists: `sh /mnt/agents/infra/setup-dart.sh`).
Mandatory coverage per package:
- shared: haversine vs known city pairs, polyline6 round-trip, turn angles.
- router_engine: parse a **synthetic .osm.pbf** built by the package's own PBF *writer* fixture (also required: writer in `test/`), grid-city route correctness, oneway respect, turn-restriction respect, profile differentiation (same A→B, trekking vs fastbike differ), nearestNode, serialize/load round-trip, perf smoke (<2s for 50km-equivalent synthetic graph).
- maps_core: MVT round-trip encode/decode, tile math vs known z/x/y, clipping, Mbf store round-trip incl. random reads, geocoder prefix search + ranking.
- nav_engine: maneuver generation on synthetic routes (angle→type mapping incl. roundabout), advance triggers, off-route → reroute with fake engine.
- ride_core: Kalman rejects 100m jump outliers, GPX/TCX well-formed (parse back with own XML reader), FIT decode round-trip via own reader in test, recorder pause excludes time/distance.
- osm_bundle_tool: end-to-end tiny extract → bundle files exist & load.

## 9. Integration contracts
- C imports `router_engine` (RouterEngine, RouteResult, GeoPoint via shared re-export) and `shared`.
- B standalone; A's bundle tool imports B's writer APIs (path deps).
- D standalone.
- E imports everything via path deps.
- All path deps only — no pub.dev in packages/*.
- **Cross-package imports use RELATIVE paths** (no pubspec/pub get needed), e.g. `import '../../shared/lib/shared.dart';` from a file in `packages/router_engine/lib/`. This keeps everything runnable with the bare Dart SDK.
