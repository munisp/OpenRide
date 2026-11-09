/// Contract C1 — job launch deep link (`openride.job.v1`).
///
/// The DeliveryPlatform driver app launches OpenRide with
/// `openride://job?payload=<base64url(JSON)>`. This module parses and
/// validates that payload into a typed [JobPayload].
library;

import 'dart:convert';

import 'package:shared/shared.dart';

/// A geographic endpoint (pickup / dropoff / via-stop) with optional label.
class JobStop {
  final double lat;
  final double lon;
  final String? address;

  const JobStop({required this.lat, required this.lon, this.address});

  GeoPoint get point => GeoPoint(lat, lon);

  factory JobStop.fromJson(Object? raw, String ctx) {
    if (raw is! Map) throw FormatException('$ctx: expected object, got $raw');
    final lat = _coord(raw['lat'], 'lat', -90, 90, ctx);
    final lon = _coord(raw['lon'], 'lon', -180, 180, ctx);
    final address = raw['address'];
    if (address != null && address is! String) {
      throw FormatException('$ctx.address: expected string, got $address');
    }
    return JobStop(lat: lat, lon: lon, address: address as String?);
  }

  static double _coord(Object? v, String key, double min, double max, String ctx) {
    final d = switch (v) {
      int i => i.toDouble(),
      double d => d,
      _ => throw FormatException('$ctx.$key: expected number, got $v'),
    };
    if (d.isNaN || d < min || d > max) {
      throw FormatException('$ctx.$key: $d out of range [$min, $max]');
    }
    return d;
  }

  Map<String, Object?> toJson() =>
      {'lat': lat, 'lon': lon, if (address != null) 'address': address};

  @override
  bool operator ==(Object other) =>
      other is JobStop && other.lat == lat && other.lon == lon && other.address == address;

  @override
  int get hashCode => Object.hash(lat, lon, address);

  @override
  String toString() => 'JobStop($lat, $lon${address == null ? '' : ', "$address"'})';
}

enum JobKind { ride, delivery }

/// Where the completed track summary should be uploaded (Contract C2 target).
class UploadTarget {
  final Uri url;
  final String token;

  const UploadTarget({required this.url, required this.token});

  factory UploadTarget.fromJson(Object? raw) {
    if (raw is! Map) throw FormatException('upload: expected object, got $raw');
    final url = raw['url'];
    final token = raw['token'];
    if (url is! String || url.isEmpty) {
      throw FormatException('upload.url: expected non-empty string, got $url');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('http') && !uri.isScheme('https')) {
      throw FormatException('upload.url: not an http(s) URL: $url');
    }
    if (token is! String || token.isEmpty) {
      throw FormatException('upload.token: expected non-empty string');
    }
    return UploadTarget(url: uri, token: token);
  }

  Map<String, Object?> toJson() => {'url': url.toString(), 'token': token};

  @override
  bool operator ==(Object other) =>
      other is UploadTarget && other.url == url && other.token == token;

  @override
  int get hashCode => Object.hash(url, token);
}

/// A validated `openride.job.v1` job payload.
class JobPayload {
  static const String schema = 'openride.job.v1';

  final String jobId;
  final JobKind kind;
  final Profile profile;
  final JobStop pickup;
  final JobStop dropoff;
  final List<JobStop> stops;
  final String bundleCity;
  final UploadTarget? upload;
  final String? callbackScheme;

  const JobPayload({
    required this.jobId,
    required this.kind,
    required this.profile,
    required this.pickup,
    required this.dropoff,
    this.stops = const [],
    required this.bundleCity,
    this.upload,
    this.callbackScheme,
  });

  /// All waypoints in order: pickup, stops..., dropoff.
  List<GeoPoint> get waypoints =>
      [pickup.point, for (final s in stops) s.point, dropoff.point];

  /// Parses `openride://job?payload=<base64url(JSON)>`.
  static JobPayload parseDeepLink(String link) {
    final uri = Uri.tryParse(link.trim());
    if (uri == null || !uri.isScheme('openride')) {
      throw FormatException('job deep link must use the openride:// scheme: $link');
    }
    // openride://job?... — 'job' arrives as host.
    if (uri.host != 'job') {
      throw FormatException('job deep link must be openride://job, got openride://${uri.host}');
    }
    final encoded = uri.queryParameters['payload'];
    if (encoded == null || encoded.isEmpty) {
      throw const FormatException('job deep link is missing the payload parameter');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))));
    } catch (e) {
      throw FormatException('job payload is not valid base64url-encoded JSON: $e');
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('job payload: expected JSON object, got $decoded');
    }
    return JobPayload.fromJson(decoded);
  }

  /// Builds the deep link for [payload] (inverse of [parseDeepLink]; used by
  /// the launcher side and by tests).
  static String buildDeepLink(JobPayload payload) {
    final encoded = base64Url.encode(utf8.encode(jsonEncode(payload.toJson())));
    return 'openride://job?payload=$encoded';
  }

  factory JobPayload.fromJson(Map<String, Object?> j) {
    final schema = j['schema'];
    if (schema != JobPayload.schema) {
      throw FormatException('schema: expected ${JobPayload.schema}, got $schema');
    }
    final jobId = j['jobId'];
    if (jobId is! String || jobId.isEmpty) {
      throw FormatException('jobId: expected non-empty string, got $jobId');
    }
    final kindRaw = j['kind'];
    final kind = JobKind.values.where((k) => k.name == kindRaw).firstOrNull;
    if (kind == null) {
      throw FormatException('kind: expected ride|delivery, got $kindRaw');
    }
    final profileRaw = j['profile'];
    if (profileRaw is! String) {
      throw FormatException('profile: expected string, got $profileRaw');
    }
    final profile = Profile.values.where((p) => p.name == profileRaw).firstOrNull;
    if (profile == null) {
      throw FormatException(
          'profile: unknown OpenRide profile "$profileRaw" '
          '(known: ${Profile.values.map((p) => p.name).join(', ')})');
    }
    final pickup = JobStop.fromJson(j['pickup'], 'pickup');
    final dropoff = JobStop.fromJson(j['dropoff'], 'dropoff');
    final stopsRaw = j['stops'];
    final stops = <JobStop>[];
    if (stopsRaw != null) {
      if (stopsRaw is! List) {
        throw FormatException('stops: expected array, got $stopsRaw');
      }
      for (var i = 0; i < stopsRaw.length; i++) {
        stops.add(JobStop.fromJson(stopsRaw[i], 'stops[$i]'));
      }
    }
    final bundleCity = j['bundleCity'];
    if (bundleCity is! String || bundleCity.isEmpty) {
      throw FormatException('bundleCity: expected non-empty string, got $bundleCity');
    }
    final uploadRaw = j['upload'];
    final upload = uploadRaw == null ? null : UploadTarget.fromJson(uploadRaw);
    final callbackScheme = j['callbackScheme'];
    if (callbackScheme != null && callbackScheme is! String) {
      throw FormatException('callbackScheme: expected string, got $callbackScheme');
    }
    return JobPayload(
      jobId: jobId,
      kind: kind,
      profile: profile,
      pickup: pickup,
      dropoff: dropoff,
      stops: stops,
      bundleCity: bundleCity,
      upload: upload,
      callbackScheme: callbackScheme as String?,
    );
  }

  Map<String, Object?> toJson() => {
        'schema': schema,
        'jobId': jobId,
        'kind': kind.name,
        'profile': profile.name,
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        if (stops.isNotEmpty) 'stops': [for (final s in stops) s.toJson()],
        'bundleCity': bundleCity,
        if (upload != null) 'upload': upload!.toJson(),
        if (callbackScheme != null) 'callbackScheme': callbackScheme,
      };

  @override
  String toString() =>
      'JobPayload($jobId, ${kind.name}, ${profile.name}, ${pickup.point} -> ${dropoff.point}, '
      '${stops.length} stops, bundle=$bundleCity)';
}
