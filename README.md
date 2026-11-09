# OpenRide — Offline Route Planner, Navigator & Ride Recorder

Fully offline cycling/trekking navigation for **iOS and Android**, built with **Flutter**.
Routing, maps and place search all run **on the phone** from OpenStreetMap data —
**no account, no backend, no network at runtime**.

- **Routing**: BRouter routing engine ported to pure Dart (`packages/router_engine`) —
  real `.osm.pbf` parsing, BRouter-style profile cost model (trekking, fastbike, roadbike,
  mtb, car-fast, car-eco, foot), bidirectional A* with turn costs, turn restrictions and
  SRTM elevation.
- **Maps**: self-contained vector tile pipeline (`packages/maps_core`) — MVT encoder/decoder,
  OSM→tiles builder (z0–15), single-file `.mbf` tile store, pure-Dart render model drawn by a
  Flutter `CustomPainter`.
- **Place search**: offline geocoder (`packages/maps_core`) — tokenized inverted index with
  prefix search and proximity ranking, built from the same OSM extract.
- **Navigation**: turn-by-turn engine (`packages/nav_engine`) — maneuver generation
  (incl. roundabout exit counting), snap-to-route, voice prompts (200 m / 50 m / at turn),
  sustained off-route detection with automatic rerouting.
- **Recording**: `packages/ride_core` — Kalman-smoothed GPS, BLE heart rate / cadence / power,
  barometric elevation, pause/resume, and real **GPX 1.1 / TCX / FIT** binary export.
  Append-only crash-safe local storage. All data stays on the device.

## Repository layout

```
packages/
  shared/           geo primitives (haversine, polyline6, turn angles)
  router_engine/    BRouter port: PBF parser, routing graph, profiles, A*
  maps_core/        MVT codec, .mbf tile store, render theme/model, geocoder
  nav_engine/       turn-by-turn navigation state machine
  ride_core/        recording, Kalman, sensors model, GPX/TCX/FIT, storage
  osm_bundle_tool/  CLI + library: .osm.pbf -> offline bundle
app/                Flutter application (iOS/Android)
test/integration/   end-to-end pipeline test
```

All `packages/*` are **pure Dart with zero external dependencies** and are consumed
via pub **path dependencies** (offline-friendly).

## Building an offline data bundle

Download an `.osm.pbf` extract (e.g. from Geofabrik), then:

```bash
dart run packages/osm_bundle_tool/bin/build_bundle.dart nigeria-latest.osm.pbf bundles/nigeria/
# produces: graph.bin, tiles.mbf, geocoder.bin, meta.json
```

Or import the `.osm.pbf` directly in the app (Settings → Offline Data) — the same builder
runs in a background isolate on the phone.

## Running the engine tests (no Flutter needed)

Requires only a Dart SDK (3.0+). All packages resolve offline:

```bash
cd packages/shared         && dart pub get --offline && dart run test/run_tests.dart
cd packages/router_engine  && dart pub get --offline && dart run test/run_tests.dart
cd packages/maps_core      && dart pub get --offline && dart run test/run_tests.dart
cd packages/nav_engine     && dart pub get --offline && dart run test/run_tests.dart
cd packages/ride_core      && dart pub get --offline && dart run test/run_tests.dart
cd packages/osm_bundle_tool && dart pub get --offline && dart run test/run_tests.dart
# full pipeline (pbf -> bundle -> route -> navigate -> record -> export -> render/geocode):
dart pub get --offline && dart run test/integration/run_tests.dart
```

Current status: **92 checks passing** (71 unit + 21 end-to-end), `dart analyze --fatal-warnings`
clean in every package.

## Building the app

```bash
cd app
flutter create .        # fills generated runner scaffolding (icons, gradle wrapper, Podfile)
flutter pub get
flutter analyze
flutter run             # or: flutter build apk / flutter build ios
```

See `app/README.md` for permissions, background modes and the offline-data import flow.
