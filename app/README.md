# OpenRide app

Flutter shell for OpenRide — a **fully offline** route planner, turn-by-turn
navigator and ride recorder (iOS/Android). All routing, map rendering, place
search and recording run on-device from OpenStreetMap data via the pure-Dart
engine packages in `../packages/*` (path dependencies; see SPEC §7).

## Build & run

A Flutter SDK (3.22+ recommended, Dart ≥ 3.4) is required.

```sh
cd app
flutter create .          # fills in generated runner scaffolding not tracked
                          # in git (icons, Pods project files, gradle wrapper,
                          # debug/profile manifests). Existing tracked files
                          # (AndroidManifest.xml, Info.plist, build.gradle,
                          # Kotlin/Swift sources) are NOT overwritten.
flutter pub get
flutter run               # or: flutter build apk / flutter build ipa
```

The engine packages are declared as path deps (`../packages/shared`, …), so
`flutter pub get` works offline — no pub.dev access is needed for the OpenRide
code itself (the Flutter plugins below do come from pub.dev).

**Import note:** app code references the engine packages via *relative*
imports (`'../../packages/router_engine/lib/router_engine.dart'`), not
`package:` URIs. Reason: SPEC §9 mandates relative cross-package imports
inside `packages/*` (e.g. `router_engine` imports `../../shared/lib/...`),
and such relative escapes do not resolve when a library is loaded through a
`package:` URI (they would incorrectly re-anchor inside that package's
`lib/`). Relative imports from the app keep every engine library anchored at
its real file location — verified with the Dart CFE (`dart run`).

## Features → screens

| Tab      | What it does |
|----------|--------------|
| Plan     | Offline vector map (CustomPainter over maps_core DrawCommands), pan/pinch, long-press to set start/destination/via, profile picker (all 7 BRouter profiles), offline place search, route computed in a background isolate, polyline + turn-by-turn list. |
| Navigate | Next-maneuver banner (icon/instruction/distance), live position & heading, remaining distance/ETA, automatic off-route rerouting via nav_engine, optional voice prompts (flutter_tts). |
| Record   | Start/pause/resume/stop ride recording (Kalman-filtered GPS), live stats grid, BLE sensor scan/connect (HR 0x180D, CSC 0x1816, Power 0x1818), barometric elevation, Android foreground service + wakelock. |
| History  | Saved rides (append-only binary store), detail with stats + track sparkline, GPX/TCX/FIT export to a temp file + system share sheet, delete. |
| Settings | Default routing profile, voice on/off, app theme + dark map theme, Offline Data manager. |

## Offline data flow

Routing/maps/search need a **bundle** built from an `.osm.pbf` extract
(e.g. [Geofabrik](https://download.geofabrik.de/) region):

1. Settings → Offline data → **Import .osm.pbf extract** (file_picker).
2. The bundle build (graph.bin + tiles.mbf + geocoder.bin + meta.json, the
   same `buildBundle()` logic as the osm_bundle_tool CLI) runs in a background
   isolate — large extracts take minutes.
3. The bundle is listed with its bounds and size; tap to **activate**. The
   first imported bundle activates automatically.

Bundles and rides live under the app documents directory
(`bundles/<name>/`, `rides_store/`). No account, no backend, no analytics:
the app requests **no INTERNET permission** on Android.

## Permissions rationale

| Permission | Why |
|---|---|
| `ACCESS_FINE_LOCATION` / `NSLocationWhenInUse` | Position on map, navigation, ride recording. |
| `ACCESS_BACKGROUND_LOCATION` / `NSLocationAlwaysAndWhenInUse` + `UIBackgroundModes: location` | Keep recording & guidance alive with the screen off. |
| `FOREGROUND_SERVICE(_LOCATION)` + `POST_NOTIFICATIONS` | Android foreground service with the mandatory ongoing "Recording ride" notification. |
| `BLUETOOTH_SCAN` (`neverForLocation`) / `BLUETOOTH_CONNECT` / `NSBluetoothAlways` | Connect to BLE HR / speed-cadence / power sensors. Legacy `BLUETOOTH(_ADMIN)` are declared `maxSdkVersion=30`. |
| `NSMotionUsageDescription` / `UIBackgroundModes: bluetooth-central` | Barometer (elevation) and backgrounded BLE on iOS. |

## Architecture notes

- `lib/platform/` — small interfaces wrapping geolocator, flutter_blue_plus
  (with real GATT parsers for 0x2A37/0x2A5B/0x2A63), sensors_plus (barometric
  formula), flutter_tts, plus the Android foreground-service MethodChannel.
- `lib/data/` — bundle manager, background-isolate routing/bundle builds,
  recording & navigation controllers (ChangeNotifier singletons held by
  `AppState`, so recording/navigation survive tab switches).
- `lib/map/` — web-mercator viewport math reusing maps_core tile helpers,
  tile decode cache, CustomPainter for DrawCommands + route/markers/position.
- No external state-management or networking packages by design (SPEC §7.4).

## Known environment note

This repository was authored without a Flutter SDK present; app code is
written against the real engine sources in `../packages/*` and the pinned
plugin APIs in `pubspec.yaml`. Run `flutter analyze` after `flutter create .`
on a dev machine as the first verification step.
