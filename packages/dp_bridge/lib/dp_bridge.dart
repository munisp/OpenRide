/// OpenRide ↔ DeliveryPlatform bridge package (Phases 1–3, INTEGRATION_SPEC).
///
///  * C1 — job launch deep links: [JobPayload] parse/validate + [JobNavigator]
///  * C2 — track telemetry: [TrackSummary] + [UploadQueue] (store-and-forward)
///  * C3 — bundle distribution: [BundleManifest] + [BundleDownloader]
///
/// Pure Dart, zero external dependencies. The C3 geocoder service lives in
/// `tools/geo_server.dart` (run with `dart run tools/geo_server.dart`).
library dp_bridge;

export 'src/sha256.dart';
export 'src/job_payload.dart';
export 'src/track_summary.dart';
export 'src/upload_queue.dart';
export 'src/bundle_manifest.dart';
export 'src/bundle_downloader.dart';
export 'src/job_navigator.dart';
export 'src/geo_server.dart';
