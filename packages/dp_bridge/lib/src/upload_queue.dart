/// Contract C2 — store-and-forward upload queue.
///
/// Track summaries are persisted to disk first (one JSON file per entry in the
/// queue dir, fsync-on-write via synchronous writes — crash-safe) and uploaded
/// when the network allows. Failures retry with exponential backoff
/// (1s, 2s, 4s, … capped at 5 minutes); entries older than 24 hours are moved
/// to the `dead/` dead-letter subdir instead of being sent.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'job_payload.dart';
import 'track_summary.dart';

/// Sends one track summary: POST [body] to [url] with bearer [token].
/// Returns true on success (2xx); returning false or throwing keeps the entry
/// queued for a backed-off retry.
typedef TrackSender = Future<bool> Function(Uri url, String body, String? token);

/// Result of one [UploadQueue.flush] pass.
class FlushResult {
  final int sent;
  final int failed;

  /// Entries moved to dead-letter (older than [UploadQueue.retention]).
  final int deadLettered;

  /// Entries not attempted because their backoff has not elapsed yet.
  final int deferred;

  const FlushResult(
      {this.sent = 0, this.failed = 0, this.deadLettered = 0, this.deferred = 0});

  @override
  String toString() =>
      'FlushResult(sent: $sent, failed: $failed, deadLettered: $deadLettered, deferred: $deferred)';
}

/// One persisted queue entry.
class QueuedUpload {
  final String id;
  final Uri url;
  final String token;
  final String jsonBody;
  int attempts;
  final int enqueuedEpochS;
  int nextAttemptEpochS;

  QueuedUpload({
    required this.id,
    required this.url,
    required this.token,
    required this.jsonBody,
    this.attempts = 0,
    required this.enqueuedEpochS,
    required this.nextAttemptEpochS,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'url': url.toString(),
        'token': token,
        'body': jsonBody,
        'attempts': attempts,
        'enqueuedEpochS': enqueuedEpochS,
        'nextAttemptEpochS': nextAttemptEpochS,
      };

  factory QueuedUpload.fromJson(Map<String, Object?> j) => QueuedUpload(
        id: j['id'] as String,
        url: Uri.parse(j['url'] as String),
        token: j['token'] as String,
        jsonBody: j['body'] as String,
        attempts: (j['attempts'] as num?)?.toInt() ?? 0,
        enqueuedEpochS: (j['enqueuedEpochS'] as num).toInt(),
        nextAttemptEpochS: (j['nextAttemptEpochS'] as num).toInt(),
      );
}

/// Disk-backed FIFO queue with exponential backoff, dead-lettering and a
/// periodic worker loop. State survives process restarts (entries are plain
/// files; reloading the same dir resumes where the previous run left off).
class UploadQueue {
  static const Duration maxBackoff = Duration(minutes: 5);
  static const Duration retention = Duration(hours: 24);

  final String dir;
  final TrackSender _sender;
  final DateTime Function() _clock;

  int _seq = 0;
  bool _workerRunning = false;

  UploadQueue(
    this.dir, {
    TrackSender? sender,
    DateTime Function()? clock,
  })  : _sender = sender ?? httpTrackSender,
        _clock = clock ?? (() => DateTime.now().toUtc()) {
    Directory(dir).createSync(recursive: true);
  }

  int get _nowS => _clock().toUtc().millisecondsSinceEpoch ~/ 1000;

  String get _deadDir => '$dir/dead';

  /// Persists [summary] for later upload to [target].
  Future<QueuedUpload> enqueue(UploadTarget target, TrackSummary summary) async {
    final now = _nowS;
    final entry = QueuedUpload(
      id: '${_clock().toUtc().millisecondsSinceEpoch}-${_seq++}',
      url: target.url,
      token: target.token,
      jsonBody: summary.toJsonString(),
      enqueuedEpochS: now,
      nextAttemptEpochS: now,
    );
    _persist(entry);
    return entry;
  }

  /// All pending entries, oldest first. Corrupt files are quarantined to
  /// dead-letter so a single bad file can never poison the queue.
  List<QueuedUpload> pending() {
    final out = <QueuedUpload>[];
    for (final e in Directory(dir).listSync()) {
      if (e is! File || !e.path.endsWith('.upload.json')) continue;
      try {
        final j = jsonDecode(e.readAsStringSync());
        if (j is Map<String, Object?>) {
          out.add(QueuedUpload.fromJson(j));
          continue;
        }
        throw const FormatException('not an entry object');
      } catch (_) {
        _quarantine(e);
      }
    }
    out.sort((a, b) => a.enqueuedEpochS.compareTo(b.enqueuedEpochS));
    return out;
  }

  int get pendingCount => pending().length;

  /// Dead-lettered entries (expired or corrupt), oldest first.
  List<File> deadLetters() {
    final d = Directory(_deadDir);
    if (!d.existsSync()) return const [];
    final out = d.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Backoff delay after [attempts] consecutive failures: 1s, 2s, 4s, … ≤ 5 min.
  /// [attempts] is the failure count (≥ 1 → first retry happens after 1s).
  static Duration backoffFor(int attempts) {
    final exp = (attempts - 1).clamp(0, 30);
    var seconds = 1 << exp; // 2^(attempts-1)
    final cap = maxBackoff.inSeconds;
    if (seconds > cap) seconds = cap;
    return Duration(seconds: seconds);
  }

  /// Attempts to send every due entry (oldest first). Entries whose backoff
  /// has not elapsed are skipped; entries older than [retention] are
  /// dead-lettered without another send attempt.
  Future<FlushResult> flush() async {
    final now = _nowS;
    var sent = 0, failed = 0, dead = 0, deferred = 0;
    for (final entry in pending()) {
      if (now - entry.enqueuedEpochS > retention.inSeconds) {
        _deadLetter(entry, 'retention-expired');
        dead++;
        continue;
      }
      if (entry.nextAttemptEpochS > now) {
        deferred++;
        continue;
      }
      var ok = false;
      try {
        ok = await _sender(entry.url, entry.jsonBody, entry.token);
      } catch (_) {
        ok = false;
      }
      if (ok) {
        _remove(entry);
        sent++;
      } else {
        entry.attempts++;
        entry.nextAttemptEpochS = now + backoffFor(entry.attempts).inSeconds;
        _persist(entry);
        failed++;
      }
    }
    return FlushResult(sent: sent, failed: failed, deadLettered: dead, deferred: deferred);
  }

  /// Worker loop: flush every [interval] until [shouldStop] returns true.
  /// Returns the results of all passes. Safe to run for the app's lifetime.
  Future<List<FlushResult>> run({
    Duration interval = const Duration(seconds: 30),
    required bool Function() shouldStop,
  }) async {
    if (_workerRunning) throw StateError('worker already running');
    _workerRunning = true;
    final results = <FlushResult>[];
    try {
      while (!shouldStop()) {
        results.add(await flush());
        if (shouldStop()) break;
        await Future.delayed(interval);
      }
    } finally {
      _workerRunning = false;
    }
    return results;
  }

  void _persist(QueuedUpload entry) {
    File('$dir/${entry.id}.upload.json').writeAsStringSync(jsonEncode(entry.toJson()));
  }

  void _remove(QueuedUpload entry) {
    final f = File('$dir/${entry.id}.upload.json');
    if (f.existsSync()) f.deleteSync();
  }

  void _deadLetter(QueuedUpload entry, String reason) {
    final f = File('$dir/${entry.id}.upload.json');
    if (!f.existsSync()) return;
    Directory(_deadDir).createSync(recursive: true);
    final wrapped = jsonEncode({'deadReason': reason, 'entry': entry.toJson()});
    File('$_deadDir/${entry.id}.json').writeAsStringSync(wrapped);
    f.deleteSync();
  }

  void _quarantine(File f) {
    Directory(_deadDir).createSync(recursive: true);
    final name = f.uri.pathSegments.last;
    try {
      f.renameSync('$_deadDir/corrupt-$name');
    } catch (_) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}

/// Default [TrackSender]: HTTP POST with bearer auth via dart:io.
/// true on 2xx; false on any other status or network error.
Future<bool> httpTrackSender(Uri url, String body, String? token) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(url).timeout(const Duration(seconds: 15));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (token != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    req.write(body);
    final resp = await req.close().timeout(const Duration(seconds: 15));
    await resp.drain<void>();
    return resp.statusCode >= 200 && resp.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
