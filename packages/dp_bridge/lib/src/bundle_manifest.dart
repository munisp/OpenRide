/// Contract C3 — bundle distribution manifest (`openride.bundles.v1`).
///
/// DeliveryPlatform serves a manifest listing per-city offline bundles
/// (graph.bin / tiles.mbf / geocoder.bin) with sha256 integrity pins.
library;

import 'dart:convert';
import 'dart:io';

import 'package:shared/shared.dart';

/// One downloadable bundle artifact with its integrity pin.
class BundleFileRef {
  final Uri url;
  final String sha256;

  const BundleFileRef({required this.url, required this.sha256});

  factory BundleFileRef.fromJson(Object? raw, String ctx) {
    if (raw is! Map) throw FormatException('$ctx: expected object, got $raw');
    final url = raw['url'];
    final sha = raw['sha256'];
    if (url is! String || url.isEmpty) {
      throw FormatException('$ctx.url: expected non-empty string, got $url');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
      throw FormatException('$ctx.url: not an http(s) URL: $url');
    }
    if (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw FormatException('$ctx.sha256: expected 64 lowercase hex chars, got $sha');
    }
    return BundleFileRef(url: uri, sha256: sha);
  }

  Map<String, Object?> toJson() => {'url': url.toString(), 'sha256': sha256};
}

/// One city's offline bundle as described by the manifest.
class RemoteBundle {
  /// Well-known artifact keys and their on-disk file names.
  static const Map<String, String> fileNames = {
    'graph': 'graph.bin',
    'tiles': 'tiles.mbf',
    'geocoder': 'geocoder.bin',
  };

  final String city;
  final String version;
  final GeoBounds bounds;
  final int sizeBytes;

  /// Keys are artifact ids ('graph', 'tiles', 'geocoder').
  final Map<String, BundleFileRef> files;

  const RemoteBundle({
    required this.city,
    required this.version,
    required this.bounds,
    required this.sizeBytes,
    required this.files,
  });

  factory RemoteBundle.fromJson(Object? raw) {
    if (raw is! Map) throw FormatException('bundle: expected object, got $raw');
    final city = raw['city'];
    if (city is! String || city.isEmpty || city.contains('/')) {
      throw FormatException('bundle.city: expected non-empty path-safe string, got $city');
    }
    final version = raw['version'];
    if (version is! String || version.isEmpty) {
      throw FormatException('bundle[$city].version: expected non-empty string');
    }
    final b = raw['bounds'];
    if (b is! Map) throw FormatException('bundle[$city].bounds: expected object');
    double numField(String k) {
      final v = b[k];
      if (v is! num) {
        throw FormatException('bundle[$city].bounds.$k: expected number');
      }
      return v.toDouble();
    }

    final bounds =
        GeoBounds(numField('minLat'), numField('minLon'), numField('maxLat'), numField('maxLon'));
    final filesRaw = raw['files'];
    if (filesRaw is! Map) {
      throw FormatException('bundle[$city].files: expected object');
    }
    final files = <String, BundleFileRef>{};
    for (final entry in filesRaw.entries) {
      files[entry.key.toString()] =
          BundleFileRef.fromJson(entry.value, 'bundle[$city].files.${entry.key}');
    }
    for (final requiredKey in fileNames.keys) {
      if (!files.containsKey(requiredKey)) {
        throw FormatException('bundle[$city].files: missing "$requiredKey" artifact');
      }
    }
    final size = raw['sizeBytes'];
    return RemoteBundle(
      city: city,
      version: version,
      bounds: bounds,
      sizeBytes: size is num ? size.toInt() : 0,
      files: files,
    );
  }

  /// On-disk file name for artifact [key] (manifest key or URL basename).
  String fileNameFor(String key) =>
      fileNames[key] ?? Uri.parse(files[key]!.url.toString()).pathSegments.last;

  Map<String, Object?> toJson() => {
        'city': city,
        'version': version,
        'bounds': {
          'minLat': bounds.minLat,
          'minLon': bounds.minLon,
          'maxLat': bounds.maxLat,
          'maxLon': bounds.maxLon,
        },
        'sizeBytes': sizeBytes,
        'files': {for (final e in files.entries) e.key: e.value.toJson()},
      };
}

/// Parsed `openride.bundles.v1` manifest.
class BundleManifest {
  static const String schema = 'openride.bundles.v1';

  final List<RemoteBundle> bundles;

  const BundleManifest(this.bundles);

  static BundleManifest parse(String jsonText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } catch (e) {
      throw FormatException('bundle manifest is not valid JSON: $e');
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('bundle manifest: expected JSON object');
    }
    if (decoded['schema'] != schema) {
      throw FormatException('bundle manifest schema: expected $schema, got ${decoded['schema']}');
    }
    final list = decoded['bundles'];
    if (list is! List) {
      throw FormatException('bundle manifest: "bundles" must be an array');
    }
    return BundleManifest([for (final b in list) RemoteBundle.fromJson(b)]);
  }

  RemoteBundle? forCity(String city) {
    for (final b in bundles) {
      if (b.city == city) return b;
    }
    return null;
  }
}

/// Fetches a JSON document as text. Injectable for tests.
typedef JsonGet = Future<String> Function(Uri url);

/// Retrieves and parses the bundle manifest from DeliveryPlatform.
class BundleManifestClient {
  final JsonGet _getJson;

  BundleManifestClient({JsonGet? getJson}) : _getJson = getJson ?? httpGetJson;

  Future<BundleManifest> fetch(Uri manifestUrl) async =>
      BundleManifest.parse(await _getJson(manifestUrl));

  /// Default HTTP GET (dart:io); throws on non-2xx.
  static Future<String> httpGetJson(Uri url) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(url).timeout(const Duration(seconds: 15));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('manifest fetch failed with status ${resp.statusCode}',
            uri: url);
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }
}
