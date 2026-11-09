/// Background-isolate entrypoints for CPU/IO-heavy engine work
/// (SPEC §7: routing "in an isolate or async", bundle build in a background
/// isolate). Everything here is `dart:isolate` + the pure-Dart engine
/// packages; results are plain data, safe to pass across isolates.
library;

import 'dart:isolate';

import 'package:osm_bundle_tool/osm_bundle_tool.dart';
import 'package:router_engine/router_engine.dart';

/// Result envelope for an off-thread route computation. When [error] is
/// non-null the route failed (e.g. NoRouteException).
typedef RouteOutcome = ({RouteResult? route, String? error});

/// Loads the graph from [bundleDir] inside a fresh isolate and computes the
/// route there, keeping the UI thread free. Errors (including
/// [NoRouteException]) are captured and returned as [RouteOutcome.error].
Future<RouteOutcome> computeRouteInIsolate({
  required String bundleDir,
  required GeoPoint from,
  required GeoPoint to,
  required List<GeoPoint> via,
  required Profile profile,
}) async {
  try {
    final result = await Isolate.run<RouteOutcome>(() async {
      final engine = createRouterEngine();
      await engine.loadGraph(bundleDir);
      try {
        final route = engine.route(RouteRequest(
          from: from,
          to: to,
          via: via,
          profile: profile,
        ));
        return (route: route, error: null);
      } on Exception catch (e) {
        return (route: null, error: e.toString());
      }
    });
    return result;
  } on Exception catch (e) {
    return (route: null, error: e.toString());
  }
}

/// Runs the osm_bundle_tool build in a background isolate. Returns the
/// meta.json summary map on success; throws on failure.
Future<Map<String, Object>> buildBundleInIsolate(
    String pbfPath, String outDir) {
  return Isolate.run(() => buildBundle(pbfPath, outDir));
}

/// Main-isolate router used by navigation auto-reroute (nav_engine's
/// Navigator calls `engine.route()` synchronously, so a live engine must
/// exist on the caller's isolate).
class RouterService {
  final RouterEngine _engine = createRouterEngine();
  String? _loadedDir;

  RouterEngine get engine => _engine;
  bool get isLoaded => _loadedDir != null;
  String? get loadedDir => _loadedDir;

  /// Loads (or reloads) the graph for [bundleDir]. Async; graph parsing is a
  /// fast binary read so main-thread load is acceptable at activation time.
  Future<void> load(String bundleDir) async {
    if (_loadedDir == bundleDir) return;
    await _engine.loadGraph(bundleDir);
    _loadedDir = bundleDir;
  }
}
