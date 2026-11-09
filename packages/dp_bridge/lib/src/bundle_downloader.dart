/// Contract C3 — remote bundle downloader.
///
/// Downloads bundle artifacts with sha256 verification and HTTP Range resume,
/// then activates them atomically (directory swap) so the app never sees a
/// half-written bundle.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'bundle_manifest.dart';
import 'sha256.dart';

/// Minimal HTTP response surface the downloader needs.
class DownloadResponse {
  final int statusCode;
  final Stream<List<int>> body;
  final int? contentLength;

  const DownloadResponse({
    required this.statusCode,
    required this.body,
    this.contentLength,
  });
}

/// HTTP GET used by the downloader. [resumeFrom] > 0 means the caller holds a
/// partial file of that many bytes and a `Range: bytes=<resumeFrom>-` request
/// must be issued (206 expected; a 200 means the server restarted the file).
typedef BundleHttpGet = Future<DownloadResponse> Function(Uri url, {int resumeFrom});

class DownloadException implements Exception {
  final String message;
  const DownloadException(this.message);
  @override
  String toString() => 'DownloadException: $message';
}

/// Marker written into an activated bundle directory by [BundleDownloader].
const String kRemoteMarkerFile = 'dp_bundle.json';

class BundleDownloader {
  /// Root directory under which `<city>/` bundle directories live.
  final String rootDir;
  final BundleHttpGet _httpGet;
  final DateTime Function() _clock;

  BundleDownloader(
    this.rootDir, {
    BundleHttpGet? httpGet,
    DateTime Function()? clock,
  })  : _httpGet = httpGet ?? defaultHttpGet,
        _clock = clock ?? (() => DateTime.now().toUtc()) {
    Directory(rootDir).createSync(recursive: true);
  }

  /// Version string of the currently installed remote bundle, if any.
  Future<String?> installedVersion(String city) async {
    final f = File('$rootDir/$city/$kRemoteMarkerFile');
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(f.readAsStringSync());
      if (j is Map && j['version'] is String) return j['version'] as String;
    } catch (_) {}
    return null;
  }

  /// True when the installed bundle is missing or has a different version.
  Future<bool> needsUpdate(RemoteBundle bundle) async =>
      (await installedVersion(bundle.city)) != bundle.version;

  /// Downloads and activates [bundle]. Returns the activated directory.
  ///
  /// Stages into `<root>/.download-<city>/`, keeping verified completed files
  /// and resumable `.part` files across calls, then swaps atomically into
  /// `<root>/<city>/`.
  Future<Directory> install(
    RemoteBundle bundle, {
    void Function(String file, int doneBytes, int? totalBytes)? onProgress,
  }) async {
    final staging = Directory('$rootDir/.download-${bundle.city}');
    staging.createSync(recursive: true);

    for (final entry in bundle.files.entries) {
      final fileName = bundle.fileNameFor(entry.key);
      await _downloadFile(bundle, entry.key, fileName, entry.value, staging,
          onProgress: onProgress);
    }

    // All artifacts verified — write the marker inside staging.
    File('${staging.path}/$kRemoteMarkerFile').writeAsStringSync(jsonEncode({
      'city': bundle.city,
      'version': bundle.version,
      'installedAt': _clock().toUtc().toIso8601String(),
      'files': {
        for (final e in bundle.files.entries)
          bundle.fileNameFor(e.key): e.value.sha256,
      },
    }));

    return _activate(bundle.city, staging);
  }

  Future<void> _downloadFile(
    RemoteBundle bundle,
    String key,
    String fileName,
    BundleFileRef ref,
    Directory staging, {
    void Function(String file, int doneBytes, int? totalBytes)? onProgress,
  }) async {
    final target = File('${staging.path}/$fileName');
    final part = File('${staging.path}/$fileName.part');

    // Already fully downloaded & verified in a previous run → skip.
    if (target.existsSync() && await sha256FileHex(target.path) == ref.sha256) {
      return;
    }

    var resumeFrom = part.existsSync() ? part.lengthSync() : 0;
    var resp = await _httpGet(ref.url, resumeFrom: resumeFrom);

    IOSink sink;
    var done = resumeFrom;
    if (resumeFrom > 0 && resp.statusCode == 206) {
      sink = part.openWrite(mode: FileMode.append);
    } else if (resp.statusCode == 200) {
      // Fresh download (or server ignored Range → restart from scratch).
      resumeFrom = 0;
      done = 0;
      sink = part.openWrite(mode: FileMode.write);
    } else {
      await resp.body.drain<void>();
      throw DownloadException(
          '${bundle.city}/$fileName: unexpected status ${resp.statusCode}');
    }

    final total = resp.contentLength == null
        ? null
        : resp.contentLength! + resumeFrom;
    try {
      await for (final chunk in resp.body) {
        sink.add(chunk);
        done += chunk.length;
        onProgress?.call(fileName, done, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (await sha256FileHex(part.path) != ref.sha256) {
      try {
        part.deleteSync();
      } catch (_) {}
      throw DownloadException(
          '${bundle.city}/$fileName: sha256 mismatch (expected ${ref.sha256})');
    }
    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
  }

  /// Swaps [staging] into `<root>/<city>` atomically (same-filesystem
  /// renames); any previous version is moved aside and deleted afterwards.
  Directory _activate(String city, Directory staging) {
    final dest = Directory('$rootDir/$city');
    final backup =
        Directory('$rootDir/.old-$city-${_clock().toUtc().millisecondsSinceEpoch}');
    var backedUp = false;
    if (dest.existsSync()) {
      dest.renameSync(backup.path);
      backedUp = true;
    }
    try {
      staging.renameSync(dest.path);
    } catch (e) {
      if (backedUp && !dest.existsSync()) {
        try {
          backup.renameSync(dest.path); // roll back
        } catch (_) {}
      }
      throw DownloadException('$city: activation failed: $e');
    }
    if (backedUp) {
      try {
        backup.deleteSync(recursive: true);
      } catch (_) {}
    }
    return dest;
  }

  /// Default HTTP implementation (dart:io) honoring Range resume.
  static Future<DownloadResponse> defaultHttpGet(Uri url,
      {int resumeFrom = 0}) async {
    final client = HttpClient();
    Stream<List<int>> body;
    int status;
    int? length;
    try {
      final req = await client.getUrl(url).timeout(const Duration(seconds: 30));
      if (resumeFrom > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$resumeFrom-');
      }
      final resp = await req.close().timeout(const Duration(seconds: 30));
      status = resp.statusCode;
      length = resp.contentLength >= 0 ? resp.contentLength : null;
      final controller = StreamController<List<int>>();
      resp.listen(
        controller.add,
        onError: controller.addError,
        onDone: () {
          client.close(force: true);
          controller.close();
        },
        cancelOnError: true,
      );
      body = controller.stream;
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
    return DownloadResponse(statusCode: status, body: body, contentLength: length);
  }
}
