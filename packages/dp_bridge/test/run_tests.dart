// Zero-dependency test harness for packages/dp_bridge (Contracts C1/C2/C3).
//
// Run from this package dir:  dart run test/run_tests.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dp_bridge/dp_bridge.dart';
import 'package:nav_engine/nav_engine.dart' show GeoPoint, NavState;
import 'package:ride_core/ride_core.dart';
import 'package:router_engine/router_engine.dart';
import 'package:router_engine/testing/pbf_writer.dart';

int _passed = 0;
int _failed = 0;
final List<Future<void>> _pending = [];

void t(String name, FutureOr<bool> Function() f) {
  _pending.add(() async {
    try {
      if (await f()) {
        _passed++;
        stdout.writeln('PASS $name');
      } else {
        _failed++;
        stdout.writeln('FAIL $name');
      }
    } catch (e, st) {
      _failed++;
      stdout.writeln('FAIL $name: $e\n$st');
    }
  }());
}

void expectTrue(bool v, [String? msg]) {
  if (!v) throw StateError(msg ?? 'expected true');
}

void expectEq(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) throw StateError('expected $b, got $a');
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) throw StateError('expected $b, got $a');
    }
    return;
  }
  if (a != b) throw StateError('expected $b, got $a');
}

void expectClose(double a, double b, double tol) {
  if ((a - b).abs() > tol) throw StateError('expected $b ± $tol, got $a');
}

void expectThrows(void Function() f, [String? contains]) {
  try {
    f();
  } catch (e) {
    if (contains != null && !'$e'.contains(contains)) {
      throw StateError('threw "$e", expected to contain "$contains"');
    }
    return;
  }
  throw StateError('expected throw, none occurred');
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

Map<String, Object?> sampleJobJson() => {
      'schema': 'openride.job.v1',
      'jobId': '9f1c2a3e-0000-4000-8000-abcdefabcdef',
      'kind': 'ride',
      'profile': 'fastbike',
      'pickup': {'lat': 6.5176, 'lon': 3.3787, 'address': 'University of Lagos'},
      'dropoff': {'lat': 6.4281, 'lon': 3.4219, 'address': 'Victoria Island'},
      'stops': [
        {'lat': 6.45, 'lon': 3.40, 'address': 'Midpoint'},
      ],
      'bundleCity': 'lagos',
      'upload': {
        'url': 'https://dp.example.com/trpc/openrideTelemetry.ingestTrack',
        'token': 'driver-token-123',
      },
      'callbackScheme': 'switchos://job-complete',
    };

String deepLinkOf(Map<String, Object?> json) =>
    'openride://job?payload=${base64Url.encode(utf8.encode(jsonEncode(json)))}';

Ride sampleRide() {
  final t0 = DateTime.utc(2026, 11, 9, 12, 0, 0);
  final pts = [
    TrackPoint(t0, 6.5000, 3.3700),
    TrackPoint(t0.add(const Duration(seconds: 10)), 6.5001, 3.3701),
    TrackPoint(t0.add(const Duration(seconds: 25)), 6.5002, 3.3703),
    TrackPoint(t0.add(const Duration(seconds: 40)), 6.5004, 3.3704),
  ];
  return Ride(
      id: 'r-test',
      started: t0,
      points: pts,
      stats: computeRideStats(pts));
}

TrackSummary sampleSummary() =>
    TrackSummary.fromRide(ride: sampleRide(), jobId: 'job-1', deviceId: 'dev-1');

UploadTarget sampleTarget() => UploadTarget(
    url: Uri.parse('https://dp.example.com/trpc/openrideTelemetry.ingestTrack'),
    token: 'tok');

/// Mutable fake clock for backoff/retention tests.
class FakeClock {
  DateTime now;
  FakeClock(this.now);
  DateTime call() => now;
}

/// In-memory HTTP server fake for the bundle downloader.
class FakeBundleServer {
  final Map<String, List<int>> files; // url path -> bytes
  final List<String> rangeHeaders = [];
  final List<String> requestedPaths = [];
  bool ignoreRange = false;

  FakeBundleServer(this.files);

  Future<DownloadResponse> get(Uri url, {int resumeFrom = 0}) async {
    requestedPaths.add('${url.path} resume=$resumeFrom');
    final data = files[url.path];
    if (data == null) {
      return DownloadResponse(statusCode: 404, body: const Stream.empty());
    }
    rangeHeaders.add(resumeFrom > 0 ? 'bytes=$resumeFrom-' : '(none)');
    if (ignoreRange || resumeFrom <= 0) {
      return DownloadResponse(
          statusCode: 200,
          body: Stream.fromIterable([data]),
          contentLength: data.length);
    }
    final rest = data.sublist(resumeFrom);
    return DownloadResponse(
        statusCode: 206,
        body: Stream.fromIterable([rest]),
        contentLength: rest.length);
  }
}

RemoteBundle fakeRemoteBundle(FakeBundleServer server,
    {String city = 'testville', String version = 'v1'}) {
  final files = <String, BundleFileRef>{};
  for (final key in RemoteBundle.fileNames.keys) {
    final name = RemoteBundle.fileNames[key]!;
    files[key] = BundleFileRef(
      url: Uri.parse('https://bundles.example.com/$city/$version/$name'),
      sha256: sha256Hex(server.files['/$city/$version/$name']!),
    );
  }
  return RemoteBundle(
    city: city,
    version: version,
    bounds: const GeoBounds(6.4, 3.2, 6.7, 3.55),
    sizeBytes: server.files.values.fold(0, (a, b) => a + b.length),
    files: files,
  );
}

Future<void> main() async {
  // --- sha256 -------------------------------------------------------------
  t('sha256 empty vector', () {
    expectEq(sha256Hex([]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    return true;
  });
  t('sha256 "abc" vector', () {
    expectEq(sha256String('abc'),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    return true;
  });
  t('sha256 56-byte vector (multi-block padding)', () {
    expectEq(sha256String('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
    return true;
  });
  t('sha256 chunked == one-shot', () async {
    final data = utf8.encode('x' * 100000 + 'tail');
    final h = Sha256();
    for (var i = 0; i < data.length; i += 977) {
      h.add(data.sublist(i, i + 977 > data.length ? data.length : i + 977));
    }
    final chunked = Sha256()
      ..add(data);
    final chunkedHex = _hexOf(chunked.close());
    // compare via file helper too
    final tmp = File('${Directory.systemTemp.path}/sha256test.bin');
    tmp.writeAsBytesSync(data);
    final fileHex = await sha256FileHex(tmp.path);
    tmp.deleteSync();
    expectEq(_hexOf(h.close()), chunkedHex);
    expectEq(chunkedHex, fileHex);
    return true;
  });

  // --- C1: job payload ----------------------------------------------------
  t('C1 parse valid deep link', () {
    final p = JobPayload.parseDeepLink(deepLinkOf(sampleJobJson()));
    expectEq(p.jobId, '9f1c2a3e-0000-4000-8000-abcdefabcdef');
    expectEq(p.kind, JobKind.ride);
    expectEq(p.profile, Profile.fastbike);
    expectClose(p.pickup.lat, 6.5176, 1e-9);
    expectEq(p.pickup.address, 'University of Lagos');
    expectEq(p.stops.length, 1);
    expectEq(p.bundleCity, 'lagos');
    expectEq(p.upload!.url.host, 'dp.example.com');
    expectEq(p.upload!.token, 'driver-token-123');
    expectEq(p.callbackScheme, 'switchos://job-complete');
    expectEq(p.waypoints.length, 3); // pickup, stop, dropoff
    return true;
  });
  t('C1 buildDeepLink round-trips', () {
    final p1 = JobPayload.fromJson(sampleJobJson());
    final p2 = JobPayload.parseDeepLink(JobPayload.buildDeepLink(p1));
    expectEq(p2.jobId, p1.jobId);
    expectEq(p2.pickup, p1.pickup);
    expectEq(p2.dropoff, p1.dropoff);
    expectEq(p2.stops.first, p1.stops.first);
    expectEq(p2.upload, p1.upload);
    return true;
  });
  t('C1 toJson/fromJson round-trip without optionals', () {
    final j = sampleJobJson()
      ..remove('stops')
      ..remove('upload')
      ..remove('callbackScheme');
    final p = JobPayload.fromJson(JobPayload.fromJson(j).toJson());
    expectEq(p.stops.length, 0);
    expectEq(p.upload, null);
    expectEq(p.callbackScheme, null);
    return true;
  });
  t('C1 rejects wrong schema', () {
    expectThrows(
        () => JobPayload.fromJson(sampleJobJson()..['schema'] = 'other.v9'),
        'schema');
    return true;
  });
  t('C1 rejects bad kind', () {
    expectThrows(() => JobPayload.fromJson(sampleJobJson()..['kind'] = 'walk'),
        'kind');
    return true;
  });
  t('C1 rejects unknown profile', () {
    expectThrows(
        () => JobPayload.fromJson(sampleJobJson()..['profile'] = 'rocket'),
        'profile');
    return true;
  });
  t('C1 rejects out-of-range latitude', () {
    final j = sampleJobJson();
    (j['pickup'] as Map)['lat'] = 91.0;
    expectThrows(() => JobPayload.fromJson(j), 'lat');
    return true;
  });
  t('C1 rejects missing jobId', () {
    expectThrows(() => JobPayload.fromJson(sampleJobJson()..remove('jobId')),
        'jobId');
    return true;
  });
  t('C1 rejects non-http upload url', () {
    final j = sampleJobJson();
    (j['upload'] as Map)['url'] = 'ftp://x/y';
    expectThrows(() => JobPayload.fromJson(j), 'upload.url');
    return true;
  });
  t('C1 rejects wrong deep-link scheme', () {
    expectThrows(
        () => JobPayload.parseDeepLink('https://job?payload=AAAA'), 'scheme');
    return true;
  });
  t('C1 rejects wrong deep-link host', () {
    expectThrows(
        () => JobPayload.parseDeepLink('openride://track?payload=AAAA'), 'job');
    return true;
  });
  t('C1 rejects malformed base64/json payload', () {
    expectThrows(() => JobPayload.parseDeepLink('openride://job?payload=!!!'));
    expectThrows(() => JobPayload.parseDeepLink(
        'openride://job?payload=${base64Url.encode(utf8.encode('[1,2]'))}'));
    return true;
  });
  t('C1 spec example payload parses', () {
    const link =
        'openride://job?payload=eyJzY2hlbWEiOiJvcGVucmlkZS5qb2IudjEiLCJqb2JJZCI6InUx'
        'aWQiLCJraW5kIjoicmlkZSIsInByb2ZpbGUiOiJmYXN0YmlrZSIsInBpY2t1cCI6eyJsYXQiO'
        'jYuNTE3NiwibG9uIjozLjM3ODcsImFkZHJlc3MiOiJVbml2ZXJzaXR5IG9mIExhZ29zIn0sIm'
        'Ryb3BvZmYiOnsibGF0Ijo2LjQyODEsImxvbiI6My40MjE5LCJhZGRyZXNzIjoiVmljdG9yaWE'
        'gSXNsYW5kIn0sImJ1bmRsZUNpdHkiOiJsYWdvcyJ9';
    final p = JobPayload.parseDeepLink(link);
    expectEq(p.bundleCity, 'lagos');
    expectEq(p.profile, Profile.fastbike);
    return true;
  });

  // --- C2: track summary --------------------------------------------------
  t('C2 summary from ride', () {
    final s = sampleSummary();
    expectEq(s.jobId, 'job-1');
    expectEq(s.deviceId, 'dev-1');
    expectEq(s.pointCount, 4);
    expectEq(s.dtS, [0, 10, 25, 40]);
    expectEq(s.epoch0,
        DateTime.utc(2026, 11, 9, 12).millisecondsSinceEpoch ~/ 1000);
    expectEq(s.totalTimeS, 40);
    expectTrue(s.distanceM > 0, 'distance should be positive');
    expectTrue(s.movingTimeS <= s.totalTimeS);
    expectTrue(s.polyline6.isNotEmpty);
    return true;
  });
  t('C2 polyline6 decodes back to track', () {
    final s = sampleSummary();
    final pts = s.points;
    expectEq(pts.length, 4);
    expectClose(pts[0].lat, 6.5000, 1e-6);
    expectClose(pts[0].lon, 3.3700, 1e-6);
    expectClose(pts[3].lat, 6.5004, 1e-6);
    expectClose(pts[3].lon, 3.3704, 1e-6);
    return true;
  });
  t('C2 json shape matches contract', () {
    final j = jsonDecode(sampleSummary().toJsonString()) as Map<String, Object?>;
    for (final k in [
      'schema', 'jobId', 'deviceId', 'startedAt', 'endedAt', 'distanceM',
      'movingTimeS', 'totalTimeS', 'maxSpeedMps', 'ascentM', 'descentM',
      'polyline6', 'epoch0', 'dtS', 'pointCount',
    ]) {
      expectTrue(j.containsKey(k), 'missing key $k');
    }
    expectEq(j['schema'], 'openride.track.v1');
    expectEq(j['distanceM'] is int, true);
    return true;
  });
  t('C2 empty ride summary is valid', () {
    final t0 = DateTime.utc(2026, 11, 9, 13);
    final ride =
        Ride(id: 'r0', started: t0, points: const [], stats: computeRideStats(const []));
    final s = TrackSummary.fromRide(ride: ride, jobId: 'j', deviceId: 'd');
    expectEq(s.pointCount, 0);
    expectEq(s.polyline6, '');
    expectEq(s.dtS, const <int>[]);
    expectEq(s.epoch0, t0.millisecondsSinceEpoch ~/ 1000);
    return true;
  });

  // --- C2: upload queue ---------------------------------------------------
  t('C2 queue: enqueue persists, reload sees entry', () async {
    final dir = Directory.systemTemp.createTempSync('dpq');
    try {
      final q = UploadQueue(dir.path, sender: _okSender);
      await q.enqueue(sampleTarget(), sampleSummary());
      expectEq(q.pendingCount, 1);
      final q2 = UploadQueue(dir.path, sender: _okSender);
      expectEq(q2.pendingCount, 1);
      expectEq(q2.pending().first.token, 'tok');
    } finally {
      dir.deleteSync(recursive: true);
    }
    return true;
  });
  t('C2 queue: flush success sends and removes', () async {
    final dir = Directory.systemTemp.createTempSync('dpq');
    try {
      final sent = <List<String>>[];
      final q = UploadQueue(dir.path, sender: (url, token, body) async {
        sent.add([url.toString(), token, body]);
      });
      await q.enqueue(sampleTarget(), sampleSummary());
      final r = await q.flush();
      expectEq(r.sent, 1);
      expectEq(r.failed, 0);
      expectEq(q.pendingCount, 0);
      expectEq(sent.length, 1);
      expectEq(sent[0][1], 'tok');
      final body = jsonDecode(sent[0][2]) as Map;
      expectEq(body['schema'], 'openride.track.v1');
    } finally {
      dir.deleteSync(recursive: true);
    }
    return true;
  });
  t('C2 queue: failure backs off then retries after delay', () async {
    final dir = Directory.systemTemp.createTempSync('dpq');
    try {
      final clock = FakeClock(DateTime.utc(2026, 11, 9, 14));
      var calls = 0;
      final q = UploadQueue(dir.path, clock: clock, sender: (u, t, b) async {
        calls++;
        if (calls < 3) throw const HttpException('boom');
      });
      await q.enqueue(sampleTarget(), sampleSummary());
      var r = await q.flush();
      expectEq(r.failed, 1);
      expectEq(q.pending().first.attempts, 1);
      expectEq(q.pending().first.nextAttemptEpochS,
          clock.now.millisecondsSinceEpoch ~/ 1000 + 1); // first backoff = 1s
      r = await q.flush(); // backoff not elapsed
      expectEq(r.deferred, 1);
      expectEq(calls, 1);
      clock.now = clock.now.add(const Duration(seconds: 2));
      r = await q.flush(); // second failure → backoff 2s
      expectEq(r.failed, 1);
      expectEq(calls, 2);
      clock.now = clock.now.add(const Duration(seconds: 3));
      r = await q.flush();
      expectEq(r.sent, 1);
      expectEq(calls, 3);
      expectEq(q.pendingCount, 0);
    } finally {
      dir.deleteSync(recursive: true);
    }
    return true;
  });
  t('C2 queue: backoff capped at 5 minutes', () {
    expectEq(UploadQueue.backoffFor(1).inSeconds, 1);
    expectEq(UploadQueue.backoffFor(2).inSeconds, 2);
    expectEq(UploadQueue.backoffFor(9).inSeconds, 256);
    expectEq(UploadQueue.backoffFor(10).inSeconds, 300);
    expectEq(UploadQueue.backoffFor(30).inSeconds, 300);
    return true;
  });
  t('C2 queue: entries older than 24h are dropped', () async {
    final dir = Directory.systemTemp.createTempSync('dpq');
    try {
      final clock = FakeClock(DateTime.utc(2026, 11, 9, 0));
      var calls = 0;
      final q = UploadQueue(dir.path, clock: clock, sender: (u, t, b) async {
        calls++;
      });
      await q.enqueue(sampleTarget(), sampleSummary());
      clock.now = clock.now.add(const Duration(hours: 25));
      final r = await q.flush();
      expectEq(r.dropped, 1);
      expectEq(calls, 0);
      expectEq(q.pendingCount, 0);
    } finally {
      dir.deleteSync(recursive: true);
    }
    return true;
  });

  // --- C3: manifest -------------------------------------------------------
  t('C3 manifest parse + forCity', () {
    final m = BundleManifest.parse(jsonEncode({
      'schema': 'openride.bundles.v1',
      'bundles': [
        {
          'city': 'lagos',
          'version': '2026-11-09',
          'bounds': {'minLat': 6.40, 'minLon': 3.20, 'maxLat': 6.70, 'maxLon': 3.55},
          'sizeBytes': 148000000,
          'files': {
            'graph': {'url': 'https://x/lagos/graph.bin', 'sha256': 'a' * 64},
            'tiles': {'url': 'https://x/lagos/tiles.mbf', 'sha256': 'b' * 64},
            'geocoder': {'url': 'https://x/lagos/geocoder.bin', 'sha256': 'c' * 64},
          },
        },
      ],
    }));
    final lagos = m.forCity('lagos')!;
    expectEq(lagos.version, '2026-11-09');
    expectEq(lagos.fileNameFor('tiles'), 'tiles.mbf');
    expectEq(m.forCity('abuja'), null);
    expectThrows(() => BundleManifest.parse('{"schema":"nope"}'), 'schema');
    expectThrows(() => BundleManifest.parse('not json'));
    return true;
  });
  t('C3 manifest rejects bundle missing an artifact', () {
    expectThrows(() => BundleManifest.parse(jsonEncode({
          'schema': 'openride.bundles.v1',
          'bundles': [
            {
              'city': 'lagos',
              'version': 'v1',
              'bounds': {'minLat': 6.4, 'minLon': 3.2, 'maxLat': 6.7, 'maxLon': 3.55},
              'files': {
                'graph': {'url': 'https://x/g', 'sha256': 'a' * 64},
                'tiles': {'url': 'https://x/t', 'sha256': 'b' * 64},
              },
            },
          ],
        })), 'geocoder');
    return true;
  });
  t('C3 manifest client uses injected transport', () async {
    final client = BundleManifestClient(getJson: (url) async => jsonEncode({
          'schema': 'openride.bundles.v1',
          'bundles': const [],
        }));
    final m = await client.fetch(Uri.parse('https://dp.example.com/bundles'));
    expectEq(m.bundles.length, 0);
    return true;
  });

  // --- C3: downloader -----------------------------------------------------
  Map<String, List<int>> fakeFiles(String city, String version) => {
        for (final name in RemoteBundle.fileNames.values)
          '/$city/$version/$name':
              utf8.encode('content-of-$city-$version-$name-${'x' * 500}'),
      };

  t('C3 downloader: full install with sha256 + atomic activate', () async {
    final root = Directory.systemTemp.createTempSync('dpb');
    try {
      final server = FakeBundleServer(fakeFiles('testville', 'v1'));
      final dl = BundleDownloader(root.path, httpGet: server.get);
      final bundle = fakeRemoteBundle(server);
      expectTrue(await dl.needsUpdate(bundle));
      final progress = <String>[];
      final dest = await dl.install(bundle,
          onProgress: (f, done, total) => progress.add('$f:$done/$total'));
      expectEq(dest.path, '${root.path}/testville');
      for (final name in RemoteBundle.fileNames.values) {
        final f = File('${dest.path}/$name');
        expectTrue(f.existsSync(), '$name missing');
        expectEq(
            utf8.decode(f.readAsBytesSync()),
            'content-of-testville-v1-$name-${'x' * 500}');
        expectTrue(!File('${dest.path}/$name.part').existsSync(),
            '.part should be renamed');
      }
      final marker = jsonDecode(
          File('${dest.path}/dp_bundle.json').readAsStringSync()) as Map;
      expectEq(marker['version'], 'v1');
      expectEq(marker['city'], 'testville');
      expectTrue(progress.isNotEmpty, 'progress callbacks expected');
      expectTrue(!(await dl.needsUpdate(bundle)), 'should be up to date');
      expectTrue(Directory(root.path).listSync().every(
          (e) => !e.path.contains('.download-') && !e.path.contains('.old-')),
          'no staging/backup leftovers');
    } finally {
      root.deleteSync(recursive: true);
    }
    return true;
  });
  t('C3 downloader: resumes a partial file with Range', () async {
    final root = Directory.systemTemp.createTempSync('dpb');
    try {
      final server = FakeBundleServer(fakeFiles('testville', 'v1'));
      final dl = BundleDownloader(root.path, httpGet: server.get);
      final bundle = fakeRemoteBundle(server);
      // Pre-seed a partial graph.bin (first 100 bytes).
      final staging = Directory('${root.path}/.download-testville')
        ..createSync(recursive: true);
      final full = server.files['/testville/v1/graph.bin']!;
      File('${staging.path}/graph.bin.part')
          .writeAsBytesSync(full.sublist(0, 100));
      await dl.install(bundle);
      expectTrue(server.requestedPaths.contains('/testville/v1/graph.bin resume=100'),
          'expected Range resume request, got ${server.requestedPaths}');
      final installed =
          File('${root.path}/testville/graph.bin').readAsBytesSync();
      expectEq(utf8.decode(installed), utf8.decode(full));
    } finally {
      root.deleteSync(recursive: true);
    }
    return true;
  });
  t('C3 downloader: server ignoring Range restarts cleanly', () async {
    final root = Directory.systemTemp.createTempSync('dpb');
    try {
      final server = FakeBundleServer(fakeFiles('testville', 'v1'))
        ..ignoreRange = true;
      final dl = BundleDownloader(root.path, httpGet: server.get);
      final bundle = fakeRemoteBundle(server);
      final staging = Directory('${root.path}/.download-testville')
        ..createSync(recursive: true);
      final full = server.files['/testville/v1/graph.bin']!;
      File('${staging.path}/graph.bin.part')
          .writeAsBytesSync(full.sublist(0, 100));
      await dl.install(bundle);
      final installed =
          File('${root.path}/testville/graph.bin').readAsBytesSync();
      expectEq(utf8.decode(installed), utf8.decode(full));
    } finally {
      root.deleteSync(recursive: true);
    }
    return true;
  });
  t('C3 downloader: sha256 mismatch aborts, nothing activated', () async {
    final root = Directory.systemTemp.createTempSync('dpb');
    try {
      final server = FakeBundleServer(fakeFiles('testville', 'v1'));
      final bundle = fakeRemoteBundle(server);
      // Corrupt the pinned hash for tiles.
      bundle.files['tiles'] = BundleFileRef(
          url: bundle.files['tiles']!.url, sha256: '0' * 64);
      final dl = BundleDownloader(root.path, httpGet: server.get);
      var threw = false;
      try {
        await dl.install(bundle);
      } on DownloadException catch (e) {
        threw = '$e'.contains('sha256');
      }
      expectTrue(threw, 'expected DownloadException');
      expectTrue(!Directory('${root.path}/testville').existsSync(),
          'must not activate corrupt bundle');
    } finally {
      root.deleteSync(recursive: true);
    }
    return true;
  });
  t('C3 downloader: version upgrade swaps atomically', () async {
    final root = Directory.systemTemp.createTempSync('dpb');
    try {
      final s1 = FakeBundleServer(fakeFiles('testville', 'v1'));
      final dl = BundleDownloader(root.path, httpGet: s1.get);
      await dl.install(fakeRemoteBundle(s1, version: 'v1'));
      final s2 = FakeBundleServer(fakeFiles('testville', 'v2'));
      final dl2 = BundleDownloader(root.path, httpGet: s2.get);
      final b2 = fakeRemoteBundle(s2, version: 'v2');
      expectTrue(await dl2.needsUpdate(b2));
      await dl2.install(b2);
      final marker = jsonDecode(
          File('${root.path}/testville/dp_bundle.json').readAsStringSync())
          as Map;
      expectEq(marker['version'], 'v2');
      expectEq(
          utf8.decode(
              File('${root.path}/testville/graph.bin').readAsBytesSync()),
          'content-of-testville-v2-graph.bin-${'x' * 500}');
      expectTrue(
          Directory(root.path)
              .listSync()
              .every((e) => !e.path.contains('.old-')),
          'backup dirs cleaned up');
    } finally {
      root.deleteSync(recursive: true);
    }
    return true;
  });

  // --- C1 runtime: JobNavigator end-to-end on a synthetic grid -------------
  t('C1 JobNavigator routes, navigates, records, summarizes', () async {
    final tmp = Directory.systemTemp.createTempSync('dpjn');
    try {
      final city = GridCity(12, 6.5000, 3.3700, 0.001);
      writeOsmPbf('${tmp.path}/city.osm.pbf',
          nodes: city.nodes, ways: city.ways, relations: city.relations);
      final graph = await buildGraphFromPbf('${tmp.path}/city.osm.pbf');
      graph.serializeTo('${tmp.path}/graph.bin');
      final engine = createRouterEngine();
      await engine.loadGraph(tmp.path);

      final job = JobPayload.fromJson(sampleJobJson()
        ..['pickup'] = {'lat': city.lat(0, 0), 'lon': city.lon(0, 0)}
        ..['dropoff'] = {'lat': city.lat(11, 11), 'lon': city.lon(11, 11)}
        ..remove('stops'));

      var now = DateTime.utc(2026, 11, 9, 15);
      final jn = JobNavigator(engine, clock: () => now);
      final route = jn.startJob(job);
      expectTrue(route.distM > 1000, 'route should be ~2.4 km, got ${route.distM}');

      // Walk the polyline: record + navigate. Advance the clock consistent
      // with ~5 m/s movement so the Kalman innovation gate accepts fixes.
      NavState? state;
      GeoPoint? prev;
      for (final p in route.points) {
        if (prev != null) {
          now = now.add(Duration(
              milliseconds: (prev.distanceTo(p) / 5.0 * 1000).round()));
        }
        state = jn.update(p, speedMps: 5.0, headingDeg: 45.0, accuracyM: 5.0);
        prev = p;
      }
      expectTrue(state != null && state.remainingM < 100.0,
          'should finish near destination, remaining=${state?.remainingM}');

      final summary = jn.finishJob(deviceId: 'dev-test');
      expectEq(summary.jobId, job.jobId);
      expectTrue(summary.pointCount > 10, 'points recorded');
      expectTrue(summary.distanceM > 500, 'recorded distance');
      expectEq(summary.dtS.length, summary.pointCount);
      expectEq(jn.activeJob, null);

      // The summary must be queueable + flushable end to end.
      final qdir = Directory('${tmp.path}/queue');
      final sent = <String>[];
      final q = UploadQueue(qdir.path, sender: (u, tk, body) async {
        sent.add(body);
      });
      await q.enqueue(job.upload ?? sampleTarget(), summary);
      final r = await q.flush();
      expectEq(r.sent, 1);
      final body = jsonDecode(sent.first) as Map;
      expectEq(body['jobId'], job.jobId);
      expectEq(body['pointCount'], summary.pointCount);
    } finally {
      tmp.deleteSync(recursive: true);
    }
    return true;
  });
  t('C1 JobNavigator guards: no double start, no update without job', () async {
    final tmp = Directory.systemTemp.createTempSync('dpjn');
    try {
      final city = GridCity(6, 6.5, 3.37, 0.001);
      writeOsmPbf('${tmp.path}/c.osm.pbf',
          nodes: city.nodes, ways: city.ways, relations: city.relations);
      (await buildGraphFromPbf('${tmp.path}/c.osm.pbf'))
          .serializeTo('${tmp.path}/graph.bin');
      final engine = createRouterEngine();
      await engine.loadGraph(tmp.path);
      final jn = JobNavigator(engine);
      final job = JobPayload.fromJson(sampleJobJson()
        ..['pickup'] = {'lat': city.lat(0, 0), 'lon': city.lon(0, 0)}
        ..['dropoff'] = {'lat': city.lat(5, 5), 'lon': city.lon(5, 5)}
        ..remove('stops'));
      expectThrows(() => jn.update(const GeoPoint(6.5, 3.37)), 'no active job');
      jn.startJob(job);
      expectThrows(() => jn.startJob(job), 'already active');
      jn.cancelJob();
      expectEq(jn.activeJob, null);
      jn.startJob(job); // can restart after cancel
      jn.finishJob(deviceId: 'd');
    } finally {
      tmp.deleteSync(recursive: true);
    }
    return true;
  });

  // Run all registered tests to completion (registration is synchronous,
  // execution is async).
  for (final f in _pending) {
    await f;
  }
  stdout.writeln('---');
  stdout.writeln('dp_bridge: $_passed passed, $_failed failed');
  if (_failed > 0) exit(1);
}

String _hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Future<void> _okSender(Uri url, String token, String body) async {}
