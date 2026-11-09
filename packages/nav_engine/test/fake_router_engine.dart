import '../lib/nav_engine.dart';

class FakeRouterEngine implements RouterEngine {
  final List<RouteRequest> requests = <RouteRequest>[];
  final List<RouteResult> queuedRoutes = <RouteResult>[];
  final List<String> loadedBundles = <String>[];
  Exception? nextError;

  @override
  Future<void> loadGraph(String bundlePath) async {
    loadedBundles.add(bundlePath);
  }

  @override
  RouteResult route(RouteRequest req) {
    requests.add(req);
    final error = nextError;
    if (error != null) {
      nextError = null;
      throw error;
    }
    if (queuedRoutes.isNotEmpty) return queuedRoutes.removeAt(0);
    return directRoute(req);
  }

  static RouteResult directRoute(RouteRequest req) {
    final points = <GeoPoint>[req.from, ...req.via, req.to];
    final distM = pathLengthM(points);
    final legs = <RouteLeg>[];
    for (var i = 1; i < points.length; i++) {
      final legPoints = <GeoPoint>[points[i - 1], points[i]];
      final legDistM = pathLengthM(legPoints);
      legs.add(
        RouteLeg(points: legPoints, distM: legDistM, timeS: legDistM / 5.0),
      );
    }
    return RouteResult(
      points: points,
      distM: distM,
      timeS: distM / 5.0,
      ascendM: 0,
      descendM: 0,
      legs: legs,
    );
  }
}
