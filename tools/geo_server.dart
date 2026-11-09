/// Contract C3 — server-hosted geocoder service (CLI).
///
/// Serves place search from a bundle's `geocoder.bin` over HTTP, using the
/// exact same maps_core.Geocoder code as the on-device app. DeliveryPlatform
/// runs this as a service and proxies it via tRPC `openrideGeo.search`.
///
/// Usage:
///   dart run tools/geo_server.dart --geocoder <path/to/geocoder.bin>
///   dart run tools/geo_server.dart --bundle <bundleDir>   # uses <dir>/geocoder.bin
///
/// Configuration (flags override env):
///   --geocoder <path> | GEOCODER_BIN   path to geocoder.bin (required)
///   --bundle <dir>    | GEO_BUNDLE     bundle dir containing geocoder.bin
///   --port <n>        | GEO_PORT       listen port (default 8090)
///   --bind <addr>     | GEO_BIND       bind address (default 0.0.0.0)
///
/// Endpoints:
///   GET /healthz                          -> {"status":"ok"}
///   GET /search?q=<text>[&lat=&lon=][&limit=20]
///        -> {"schema":"openride.geo.v1","query":q,
///            "results":[{"name","kind","lat","lon","score"}]}
library;

import 'dart:io';

import 'package:dp_bridge/dp_bridge.dart' show serveGeo;
import 'package:maps_core/maps_core.dart';

const String _usage = '''
geo_server — OpenRide offline geocoder HTTP service (Contract C3)

  --geocoder <path>   path to geocoder.bin   (env GEOCODER_BIN)
  --bundle <dir>      bundle dir with geocoder.bin (env GEO_BUNDLE)
  --port <n>          listen port (env GEO_PORT, default 8090)
  --bind <addr>       bind address (env GEO_BIND, default 0.0.0.0)
  --help              this text
''';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  String? geocoderPath = env['GEOCODER_BIN'];
  final bundleDir = env['GEO_BUNDLE'];
  if (geocoderPath == null && bundleDir != null) {
    geocoderPath = '$bundleDir/geocoder.bin';
  }
  var port = int.tryParse(env['GEO_PORT'] ?? '') ?? 8090;
  var bind = env['GEO_BIND'] ?? '0.0.0.0';

  for (var i = 0; i < args.length; i++) {
    String value(String flag) {
      if (i + 1 >= args.length) _fatal('$flag requires a value');
      return args[++i];
    }

    switch (args[i]) {
      case '--geocoder':
        geocoderPath = value('--geocoder');
      case '--bundle':
        geocoderPath = '${value('--bundle')}/geocoder.bin';
      case '--port':
        final parsed = int.tryParse(value('--port'));
        if (parsed == null || parsed <= 0 || parsed > 65535) {
          _fatal('invalid --port value');
        }
        port = parsed;
      case '--bind':
        bind = value('--bind');
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
    stderr.writeln('geo_server: geocoder.bin not found: $geocoderPath');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final geocoder = Geocoder()..open(geocoderPath);
  final server = await serveGeo(geocoder,
      port: port, bind: bind, log: (m) => stdout.writeln(m));
  stdout.writeln(
      'geo_server: serving $geocoderPath on http://$bind:${server.port}');
  ProcessSignal.sigterm.watch().listen((_) async {
    stdout.writeln('geo_server: SIGTERM, shutting down');
    await server.close();
    exit(0);
  });
}

Never _fatal(String message) {
  stderr.writeln('geo_server: $message');
  stderr.write(_usage);
  exit(64);
}
