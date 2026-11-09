/// Contract C3 — server-hosted geocoder service.
///
/// Serves place search from a bundle's `geocoder.bin` over HTTP, using the
/// exact same maps_core.Geocoder code as the on-device app. DeliveryPlatform
/// runs this as a service and proxies it via tRPC `openrideGeo.search`.
///
/// Usage:
///   dart run tools/geo_server.dart --geocoder <path/to/geocoder.bin> \
///       [--port 8081] [--bind 0.0.0.0]
///
/// Endpoints:
///   GET /health                          -> {"status":"ok"}
///   GET /search?q=<text>[&lat=&lon=][&limit=20]
///        -> {"schema":"openride.geo.v1","query":q,
///            "results":[{"name","kind","lat","lon","score"}]}
library;

import 'dart:convert';
import 'dart:io';

import 'package:maps_core/maps_core.dart';

const String _usage = '''
geo_server — OpenRide offline geocoder HTTP service (Contract C3)

  --geocoder <path>   path to geocoder.bin (required)
  --port <n>          listen port (default 8081)
  --bind <addr>       bind address (default 0.0.0.0)
  --help              this text
''';

Future<void> main(List<String> args) async {
  String? geocoderPath;
  var port = 8081;
  var bind = '0.0.0.0';

  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--geocoder':
        if (i + 1 >= args.length) _fatal('--geocoder requires a value');
        geocoderPath = args[++i];
      case '--port':
        if (i + 1 >= args.length) _fatal('--port requires a value');
        final parsed = int.tryParse(args[++i]);
        if (parsed == null || parsed <= 0 || parsed > 65535) {
          _fatal('invalid --port value');
        }
        port = parsed;
      case '--bind':
        if (i + 1 >= args.length) _fatal('--bind requires a value');
        bind = args[++i];
      case '--help':
        stdout.write(_usage);
        return;
      default:
        _fatal('unknown argument: ${args[i]}');
    }
  }

  if (geocoderPath == null) {
    stderr.write(_usage);
    exitCode = 64; // EX_USAGE
    return;
  }
  if (!File(geocoderPath).existsSync()) {
    stderr.writeln('geocoder.bin not found: $geocoderPath');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final geocoder = Geocoder()..open(geocoderPath);
  final server = await HttpServer.bind(bind, port);
  stdout.writeln('geo_server: serving $geocoderPath on http://$bind:${server.port}');

  await for (final req in server) {
    try {
      _handle(req, geocoder);
    } catch (e) {
      _json(req.response, 500, {'error': '$e'});
    }
    await req.response.close();
  }
}

void _handle(HttpRequest req, Geocoder geocoder) {
  final resp = req.response;
  if (req.method != 'GET') {
    _json(resp, 405, {'error': 'method not allowed'});
    return;
  }
  switch (req.uri.path) {
    case '/health':
      _json(resp, 200, {'status': 'ok'});
    case '/search':
      final q = req.uri.queryParameters['q'] ?? '';
      if (q.trim().isEmpty) {
        _json(resp, 400, {'error': 'missing query parameter q'});
        return;
      }
      final lat = double.tryParse(req.uri.queryParameters['lat'] ?? '');
      final lon = double.tryParse(req.uri.queryParameters['lon'] ?? '');
      var limit = int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 20;
      if (limit < 1) limit = 1;
      if (limit > 100) limit = 100;
      final near = (lat != null && lon != null) ? GeoPoint(lat, lon) : null;
      final hits = geocoder.search(q, near: near, limit: limit);
      _json(resp, 200, {
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
      _json(resp, 404, {'error': 'not found'});
  }
}

void _json(HttpResponse resp, int status, Map<String, Object?> body) {
  resp.statusCode = status;
  resp.headers.contentType = ContentType.json;
  resp.write(jsonEncode(body));
}

Never _fatal(String message) {
  stderr.writeln('geo_server: $message');
  stderr.write(_usage);
  exit(64);
}
