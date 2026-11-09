/// Contract C3 — server-hosted geocoder service (library part).
///
/// [serveGeo] runs an HTTP place-search service over a bundle's
/// `geocoder.bin`, using the exact same maps_core.Geocoder code as the
/// on-device app. The CLI wrapper lives at repo-root `tools/geo_server.dart`;
/// DeliveryPlatform proxies this service via tRPC `openrideGeo.search`.
///
/// Endpoints:
///   GET /healthz                              -> {"status":"ok"}
///   GET /search?q=<text>[&lat=&lon=][&limit=] -> {"results":[{name,kind,lat,lon,score}]}
/// Errors are JSON with proper status codes (400/404/405/500).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:maps_core/maps_core.dart';

/// Binds the geocoder HTTP service. [port] 0 picks an ephemeral port (tests).
Future<HttpServer> serveGeo(
  Geocoder geocoder, {
  int port = 8090,
  String bind = '0.0.0.0',
  void Function(String message)? log,
}) async {
  final server = await HttpServer.bind(bind, port);
  log?.call('geo_server: serving on http://$bind:${server.port}');
  // Fire-and-forget request pump; callers keep the server alive via the
  // returned handle and close it with server.close().
  unawaited(server.forEach((req) async {
    try {
      handleGeoRequest(req, geocoder);
    } catch (e) {
      geoJson(req.response, 500, {'error': '$e'});
    }
    await req.response.close();
  }));
  return server;
}

/// Handles one request (exported for embedding/testing).
void handleGeoRequest(HttpRequest req, Geocoder geocoder) {
  final resp = req.response;
  if (req.method != 'GET') {
    geoJson(resp, 405, {'error': 'method not allowed'});
    return;
  }
  switch (req.uri.path) {
    case '/healthz':
    case '/health': // alias for simple probes
      geoJson(resp, 200, {'status': 'ok'});
    case '/search':
      final q = req.uri.queryParameters['q'] ?? '';
      if (q.trim().isEmpty) {
        geoJson(resp, 400, {'error': 'missing query parameter q'});
        return;
      }
      final lat = double.tryParse(req.uri.queryParameters['lat'] ?? '');
      final lon = double.tryParse(req.uri.queryParameters['lon'] ?? '');
      var limit = int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 20;
      if (limit < 1) limit = 1;
      if (limit > 100) limit = 100;
      final near = (lat != null && lon != null) ? GeoPoint(lat, lon) : null;
      final hits = geocoder.search(q, near: near, limit: limit);
      geoJson(resp, 200, {
        'schema': 'openride.geo.v1',
        'query': q,
        'results': [
          for (final h in hits)
            {
              'name': h.name,
              'kind': h.kind,
              'lat': h.point.lat,
              'lon': h.point.lon,
              'score': h.score,
            },
        ],
      });
    default:
      geoJson(resp, 404, {'error': 'not found'});
  }
}

void geoJson(HttpResponse resp, int status, Map<String, Object?> body) {
  resp.statusCode = status;
  resp.headers.contentType = ContentType.json;
  resp.write(jsonEncode(body));
}
