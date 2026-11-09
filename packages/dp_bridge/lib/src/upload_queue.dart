/// Contract C2 — store-and-forward upload queue.
///
/// Track summaries are persisted to disk first and uploaded when the network
/// allows. Failures retry with exponential backoff (1s, 2s, 4s, … capped at
/// 5 minutes); entries older than 24 hours are dropped.
library;

import 'dart:convert';
import 'dart:io';

import 'job_payload.dart';
import 'track_summary.dart';

/// Sends one track summary. Throws (any object) on failure → the entry stays
/// queued and is retried with backoff.
typedef TrackSender = Future<void> Function(Uri url, String token, String jsonBody);

/// Result of one [UploadQueue.flush] pass.
class FlushResult {
  final int sent;
  final int failed;
  final int dropped;

  /// Entries not attempted because their backoff has not elapsed yet.
  final int deferred;

  const FlushResult(
      {this.sent = 0, this.failed = 0, this.dropped = 0, this.deferred = 0});

  @override
  String toString() =>
      'FlushResult(sent: $sent, failed: $failed, dropped: $dropped, deferred: $deferred)';
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

/// Disk-backed FIFO queue with exponential backoff and 24 h retention.
class UploadQueue {
  static const Duration maxBackoff = Duration(minutes: 5);
  static const Duration retention = Duration(hours: 24);

  final String dir;
  final TrackSender _sender;
  final DateTime Function() _clock;

  int _seq = 0;

  UploadQueue(
    this.dir, {
    TrackSender? sender,
    DateTime Function()? clock,
  })  : _sender = sender ?? httpTrackSender,
        _clock = clock ?? (() => DateTime.now().toUtc()) {
    Directory(dir).createSync(recursive: true);
  }

  int get _nowS => _clock().toUtc().millisecondsSinceEpoch ~/ 1000;

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

  /// All pending entries, oldest first.
  List<QueuedUpload> pending() {
    final out = <QueuedUpload>[];
    for (final e in Directory(dir).listSync()) {
      if (e is! File || !e.path.endsWith('.upload.json')) continue;
      try {
        final j = jsonDecode(e.readAsStringSync());
        if (j is Map<String, Object?>) out.add(QueuedUpload.fromJson(j));
      } catch (_) {
        // Corrupt entry: drop it rather than poison the queue forever.
        try {
          e.deleteSync();
        } catch (_) {}
      }
    }
    out.sort((a, b) => a.enqueuedEpochS.compareTo(b.enqueuedEpochS));
    return out;
  }

  int get pendingCount => pending().length;

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
  /// has not elapsed are skipped; entries older than [retention] are dropped.
  Future<FlushResult> flush() async {
    final now = _nowS;
    var sent = 0, failed = 0, dropped = 0, deferred = 0;
    for (final entry in pending()) {
      if (now - entry.enqueuedEpochS > retention.inSeconds) {
        _remove(entry);
        dropped++;
        continue;
      }
      if (entry.nextAttemptEpochS > now) {
        deferred++;
        continue;
      }
      try {
        await _sender(entry.url, entry.token, entry.jsonBody);
        _remove(entry);
        sent++;
      } catch (_) {
        entry.attempts++;
        entry.nextAttemptEpochS = now + backoffFor(entry.attempts).inSeconds;
        _persist(entry);
        failed++;
      }
    }
    return FlushResult(sent: sent, failed: failed, dropped: dropped, deferred: deferred);
  }

  void _persist(QueuedUpload entry) {
    File('$dir/${entry.id}.upload.json').writeAsStringSync(jsonEncode(entry.toJson()));
  }

  void _remove(QueuedUpload entry) {
    final f = File('$dir/${entry.id}.upload.json');
    if (f.existsSync()) f.deleteSync();
  }
}

/// Default [TrackSender]: HTTP POST with bearer auth via dart:io.
/// Any non-2xx status is treated as a (retryable) failure.
Future<void> httpTrackSender(Uri url, String token, String jsonBody) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(url).timeout(const Duration(seconds: 15));
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.write(jsonBody);
    final resp = await req.close().timeout(const Duration(seconds: 15));
    await resp.drain<void>();
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpException('upload failed with status ${resp.statusCode}', uri: url);
    }
  } finally {
    client.close(force: true);
  }
}
