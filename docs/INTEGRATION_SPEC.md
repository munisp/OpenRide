# INTEGRATION SPEC — OpenRide ↔ DeliveryPlatform (Phases 1–3)

Status: contracts FROZEN for implementation. All three phases code against this document.

DeliveryPlatform mobile = **Expo/React Native** (`mobile/switchos-native`, expo-router, tRPC client, MapLibre). OpenRide = Flutter/pure-Dart engine packages. Cross-runtime embedding (Dart-in-RN) is impractical → **app-to-app deep-link architecture**: the DeliveryPlatform driver app launches OpenRide with a job payload; OpenRide navigates offline and returns/uploads a track summary. (Flutter add-to-app embedding is a documented future option, not this phase.)

## Contract C1 — Job launch (Phase 1)

Driver app → OpenRide via deep link:
```
openride://job?payload=<base64url(JSON)>
```
```json
{
  "schema": "openride.job.v1",
  "jobId": "uuid (ride_trip.id or delivery order id)",
  "kind": "ride" | "delivery",
  "profile": "fastbike" | "trekking" | "carFast" | ... (OpenRide Profile names),
  "pickup":    {"lat": 6.5176, "lon": 3.3787, "address": "University of Lagos"},
  "dropoff":   {"lat": 6.4281, "lon": 3.4219, "address": "Victoria Island"},
  "stops":     [ {"lat": ..., "lon": ..., "address": ...} ],          // optional via-points
  "bundleCity": "lagos",                                                // which offline bundle to activate
  "upload": {"url": "https://<dp-host>/trpc/openrideTelemetry.ingestTrack", "token": "<driver session bearer>"},
  "callbackScheme": "switchos://job-complete"
}
```

## Contract C2 — Track summary upload (Phase 2)

OpenRide → DeliveryPlatform, HTTP POST JSON to `upload.url`, `Authorization: Bearer <token>`. Store-and-forward: queued locally with exponential backoff (1s,2s,…,5min cap, 24h retention) when offline.
```json
{
  "schema": "openride.track.v1",
  "jobId": "uuid",
  "deviceId": "opaque install id",
  "startedAt": "ISO-8601", "endedAt": "ISO-8601",
  "distanceM": 15490, "movingTimeS": 648, "totalTimeS": 812,
  "maxSpeedMps": 16.2, "ascentM": 34.0, "descentM": 31.0,
  "polyline6": "encoded with OpenRide shared encodePolyline6 (precision 6)",
  "epoch0": 1731234567, "dtS": [0, 3, 5, ...],   // per-point epoch-second deltas
  "pointCount": 231
}
```
Server-side verification (tRPC `openrideTelemetry.ingestTrack`, driver-authenticated):
- match `jobId` → `mobility.ride_trip` (or delivery order) assigned to the caller
- compare `distanceM` vs `fare_quote.quoted_distance_m` → `variance_pct`; flag `suspect` when > 15%
- persist to new table `mobility.trip_track` (migration `0095_openride_telemetry.sql`):
  id uuid PK, trip_id uuid FK ride_trip, driver_user_id int FK users, distance_m int, moving_time_s int,
  total_time_s int, max_speed_kph numeric, polyline6 text, point_count int, variance_pct numeric,
  verdict text CHECK IN ('ok','suspect','unverifiable'), raw jsonb, created_at timestamptz
- proof-of-delivery: for delivery orders, arrival = last point within 100 m of dropoff → `arrived_at` evidence
- read endpoints: `openrideTelemetry.getForTrip`, `openrideTelemetry.verificationSummary`

## Contract C3 — Bundle distribution (Phase 3)

Server: tRPC `openrideBundles.list` (public) → manifest:
```json
{"schema":"openride.bundles.v1","bundles":[
 {"city":"lagos","version":"2026-11-09","bounds":{"minLat":6.40,"minLon":3.20,"maxLat":6.70,"maxLon":3.55},
  "sizeBytes":148000000,"files":{"graph":{"url":"...","sha256":"..."},"tiles":{...},"geocoder":{...}}}]}
```
OpenRide bundle manager gains remote mode: fetch manifest, diff vs installed, download with sha256 verify + resume, atomic activate.
Customer-app place search: server-hosted geocoder service (Dart, dart:io HTTP, serves `/search?q=&lat=&lon=` from a bundle's geocoder.bin — same code as the app, runs as a DeliveryPlatform service); RN/PWA consumes via tRPC `openrideGeo.search` proxy.

## Implementation ownership

| Wave | Agent | Deliverables |
|---|---|---|
| I1 | OpenRide `packages/dp_bridge` (pure Dart, zero-dep, tested): C1 payload parse/validate, JobNavigator (wraps RouterEngine+Navigator+RideRecorder per job), C2 TrackSummary builder (polyline6 via shared) + UploadQueue (store-and-forward, dart:io HttpClient), C3 BundleManifest client + downloader (sha256, resume, atomic activate) + `tools/geo_server.dart` (C3 service) | OpenRide repo |
| I2 | DeliveryPlatform server: `server/openride/telemetry.ts` + `fareVerification.ts` + `bundleRegistry.ts`, `drizzle/0095_openride_telemetry.sql`, vitest tests; 3-line `server/routers.ts` registration (fetch FRESH routers.ts from GitHub main first) | push as PR branch `feat/openride-integration` |
| I3 | DeliveryPlatform Expo glue (new files only, expo-router auto-registers): `lib/openride.ts` (C1 deep-link builder/launcher via expo-linking, C2 status), `app/job-navigate.tsx` screen, `components/PlaceSearchField.tsx` (C3 via tRPC) | same PR branch |

Testing: I1 = dart run_tests.dart green. I2 = vitest green locally (dp-main copy) for verification logic (pure functions + in-memory fakes for db rows — unit level, no PG needed). I3 = tsc --noEmit clean on new files where feasible; otherwise careful review.
