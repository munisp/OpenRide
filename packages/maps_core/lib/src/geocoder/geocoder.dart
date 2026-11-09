/// Offline geocoder (SPEC §4.4).
///
/// `geocoder.bin` layout (little-endian):
/// ```
/// 0  4   magic 'GCB1'
/// 4  4   u32 entryCount
/// 8      entries × 16B: kindRef u32, nameRef u32, latE7 i32, lonE7 i32
/// .. 4   u32 stringCount
/// ..     strings × (u16 byteLen + utf8 bytes)   — the string pool
/// .. 4   u32 tokenCount
/// ..     token dict × (u16 byteLen + utf8 bytes + u32 postingsOffset + u32 postingsLen),
///        sorted lexicographically by token (binary search + prefix scan)
/// ..     postings area × (varint count, then count delta-varint entry ids)
/// ```
/// Search: tokenize the query, AND-intersect exact-token postings, prefix
/// match on the last token, rank by class weight × proximity to [near].
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared/shared.dart';
import '../osm_like.dart';

const List<int> _magic = [0x47, 0x43, 0x42, 0x31]; // 'GCB1'

class GeoSearchResult {
  final String name;
  final String kind;
  final GeoPoint point;
  final double score;
  const GeoSearchResult(
      {required this.name, required this.kind, required this.point, required this.score});

  @override
  String toString() => 'GeoSearchResult($name, $kind, $point, ${score.toStringAsFixed(3)})';
}

class _Entry {
  int kindRef, nameRef, latE7, lonE7;
  _Entry(this.kindRef, this.nameRef, this.latE7, this.lonE7);
}

bool _isTokenChar(int c) =>
    (c >= 0x61 && c <= 0x7A) || // a-z
    (c >= 0x30 && c <= 0x39) || // 0-9
    c > 0x7F; // non-ascii letters (approximation, offline-safe)

/// Lowercase alphanumeric tokenization.
List<String> tokenize(String text) {
  final tokens = <String>[];
  final sb = StringBuffer();
  for (final raw in text.toLowerCase().codeUnits) {
    if (_isTokenChar(raw)) {
      sb.writeCharCode(raw);
    } else if (sb.isNotEmpty) {
      tokens.add(sb.toString());
      sb.clear();
    }
  }
  if (sb.isNotEmpty) tokens.add(sb.toString());
  return tokens;
}

class Geocoder {
  // --- in-memory structures after open() -----------------------------------
  RandomAccessFile? _raf;
  List<String> _strings = const [];
  List<_Entry> _entries = const [];
  List<String> _tokens = const [];
  List<int> _postingOffsets = const [];
  List<int> _postingLengths = const [];

  // =========================================================================
  // build
  // =========================================================================

  /// Build `geocoder.bin` at [outPath] from an [OsmLike] source: named nodes
  /// and ways, plus address (addr:*) and amenity/shop/tourism features.
  static void build(OsmLike source, String outPath) {
    final nodesById = <int, OsmLikeNode>{};
    for (final n in source.nodes) {
      nodesById[n.id] = n;
    }

    final pool = <String, int>{};
    final strings = <String>[];
    int intern(String s) => pool.putIfAbsent(s, () {
          strings.add(s);
          return strings.length - 1;
        });

    final entries = <_Entry>[];
    final postings = <String, List<int>>{};

    String? kindOf(Map<String, String> tags) {
      if (tags['place'] != null) return 'place:${tags['place']}';
      for (final k in const ['amenity', 'shop', 'tourism']) {
        if (tags[k] != null) return '$k:${tags[k]}';
      }
      if (tags['highway'] != null) return 'highway:${tags['highway']}';
      if (tags['building'] != null) return 'building:${tags['building']}';
      if (tags['addr:housenumber'] != null || tags['addr:street'] != null) {
        return 'address';
      }
      return null;
    }

    String? nameOf(Map<String, String> tags) {
      final name = tags['name'];
      if (name != null && name.isNotEmpty) return name;
      final street = tags['addr:street'];
      final house = tags['addr:housenumber'];
      if (street != null && house != null) return '$street $house';
      if (street != null) return street;
      return null;
    }

    void addEntry(String kind, String name, double lat, double lon) {
      final idx = entries.length;
      entries.add(_Entry(
          intern(kind), intern(name), (lat * 1e7).round(), (lon * 1e7).round()));
      for (final tok in tokenize(name)) {
        final list = postings.putIfAbsent(tok, () => <int>[]);
        if (list.isEmpty || list.last != idx) list.add(idx);
      }
    }

    for (final n in source.nodes) {
      if (n.tags.isEmpty) continue;
      final name = nameOf(n.tags);
      final kind = kindOf(n.tags);
      if (name != null && kind != null) addEntry(kind, name, n.lat, n.lon);
    }
    for (final w in source.ways) {
      if (w.tags.isEmpty) continue;
      final name = nameOf(w.tags);
      final kind = kindOf(w.tags);
      if (name == null || kind == null) continue;
      double la = 0, lo = 0;
      var cnt = 0;
      for (final ref in w.refs) {
        final n = nodesById[ref];
        if (n != null) {
          la += n.lat;
          lo += n.lon;
          cnt++;
        }
      }
      if (cnt == 0) continue;
      addEntry(kind, name, la / cnt, lo / cnt);
    }

    // --- serialize -----------------------------------------------------------
    final tokens = postings.keys.toList()..sort();
    final out = File(outPath).openSync(mode: FileMode.write);
    try {
      // Header + entries.
      final head = ByteData(8 + entries.length * 16);
      for (int i = 0; i < 4; i++) {
        head.setUint8(i, _magic[i]);
      }
      head.setUint32(4, entries.length, Endian.little);
      for (int i = 0; i < entries.length; i++) {
        final e = entries[i];
        final p = 8 + i * 16;
        head.setUint32(p, e.kindRef, Endian.little);
        head.setUint32(p + 4, e.nameRef, Endian.little);
        head.setInt32(p + 8, e.latE7, Endian.little);
        head.setInt32(p + 12, e.lonE7, Endian.little);
      }
      out.writeFromSync(head.buffer.asUint8List());

      // String pool.
      final sc = ByteData(4)..setUint32(0, strings.length, Endian.little);
      out.writeFromSync(sc.buffer.asUint8List());
      for (final s in strings) {
        final bytes = utf8.encode(s);
        final lb = ByteData(2)..setUint16(0, bytes.length, Endian.little);
        out.writeFromSync(lb.buffer.asUint8List());
        out.writeFromSync(bytes);
      }

      // Token dict + postings (delta + varint).
      final postingBlobs = <Uint8List>[];
      var postingsOffset = 0;
      final tc = ByteData(4)..setUint32(0, tokens.length, Endian.little);
      out.writeFromSync(tc.buffer.asUint8List());
      // Dict entries carry absolute offsets; dict size depends on itself, so
      // precompute dict length first.
      var dictLen = 0;
      for (final t in tokens) {
        dictLen += 2 + utf8.encode(t).length + 8;
      }
      final dictStart = out.positionSync();
      var blobStart = dictStart + dictLen;
      postingsOffset = blobStart;
      for (final t in tokens) {
        final ids = postings[t]!;
        final blob = BytesBuilder(copy: false);
        _writeVarintTo(blob, ids.length);
        var prev = 0;
        for (final id in ids) {
          _writeVarintTo(blob, id - prev);
          prev = id;
        }
        postingBlobs.add(Uint8List.fromList(blob.takeBytes()));
        final tb = utf8.encode(t);
        final rec = ByteData(2 + tb.length + 8);
        rec.setUint16(0, tb.length, Endian.little);
        for (int i = 0; i < tb.length; i++) {
          rec.setUint8(2 + i, tb[i]);
        }
        rec.setUint32(2 + tb.length, postingsOffset, Endian.little);
        rec.setUint32(2 + tb.length + 4, postingBlobs.last.length, Endian.little);
        postingsOffset += postingBlobs.last.length;
        out.writeFromSync(rec.buffer.asUint8List());
      }
      for (final blob in postingBlobs) {
        out.writeFromSync(blob);
      }
    } finally {
      out.closeSync();
    }
  }

  static void _writeVarintTo(BytesBuilder b, int v) {
    var value = v;
    while (value > 0x7F) {
      b.addByte((value & 0x7F) | 0x80);
      value >>= 7;
    }
    b.addByte(value);
  }

  // =========================================================================
  // open / search
  // =========================================================================

  void open(String path) {
    close();
    final raf = File(path).openSync();
    try {
      final magic = raf.readSync(4);
      if (magic.length != 4 ||
          magic[0] != _magic[0] ||
          magic[1] != _magic[1] ||
          magic[2] != _magic[2] ||
          magic[3] != _magic[3]) {
        throw FormatException('not a GCB1 file: $path');
      }
      final u32 = () {
        final b = raf.readSync(4);
        return ByteData.sublistView(b).getUint32(0, Endian.little);
      };
      final entryCount = u32();
      final entryRaw = raf.readSync(entryCount * 16);
      final ebd = ByteData.sublistView(entryRaw);
      final entries = <_Entry>[];
      for (int i = 0; i < entryCount; i++) {
        final p = i * 16;
        entries.add(_Entry(
          ebd.getUint32(p, Endian.little),
          ebd.getUint32(p + 4, Endian.little),
          ebd.getInt32(p + 8, Endian.little),
          ebd.getInt32(p + 12, Endian.little),
        ));
      }
      final stringCount = u32();
      final strings = <String>[];
      for (int i = 0; i < stringCount; i++) {
        final lb = raf.readSync(2);
        final len = ByteData.sublistView(lb).getUint16(0, Endian.little);
        strings.add(utf8.decode(raf.readSync(len)));
      }
      final tokenCount = u32();
      final tokens = <String>[];
      final offsets = <int>[];
      final lengths = <int>[];
      for (int i = 0; i < tokenCount; i++) {
        final lb = raf.readSync(2);
        final len = ByteData.sublistView(lb).getUint16(0, Endian.little);
        tokens.add(utf8.decode(raf.readSync(len)));
        final ol = raf.readSync(8);
        final obd = ByteData.sublistView(ol);
        offsets.add(obd.getUint32(0, Endian.little));
        lengths.add(obd.getUint32(4, Endian.little));
      }
      _raf = raf;
      _entries = entries;
      _strings = strings;
      _tokens = tokens;
      _postingOffsets = offsets;
      _postingLengths = lengths;
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  void close() {
    _raf?.closeSync();
    _raf = null;
  }

  Set<int>? _readPostings(int tokenIndex) {
    final raf = _raf;
    if (raf == null) throw StateError('Geocoder not open');
    raf.setPositionSync(_postingOffsets[tokenIndex]);
    final data = raf.readSync(_postingLengths[tokenIndex]);
    var pos = 0;
    int varint() {
      int result = 0, shift = 0;
      while (true) {
        final b = data[pos++];
        result |= (b & 0x7F) << shift;
        if (b < 0x80) break;
        shift += 7;
      }
      return result;
    }

    final count = varint();
    final out = <int>{};
    var prev = 0;
    for (int i = 0; i < count; i++) {
      prev += varint();
      out.add(prev);
    }
    return out;
  }

  /// Binary search: index of first token >= [prefix], or -1 if none.
  int _lowerBound(String prefix) {
    var lo = 0, hi = _tokens.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_tokens[mid].compareTo(prefix) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < _tokens.length ? lo : -1;
  }

  /// Class weight for ranking.
  static double classWeight(String kind) {
    const w = {
      'place:city': 1.0,
      'place:town': 0.95,
      'place:village': 0.9,
      'place:suburb': 0.85,
      'place:hamlet': 0.8,
      'address': 0.45,
    };
    final exact = w[kind];
    if (exact != null) return exact;
    if (kind.startsWith('tourism:')) return 0.65;
    if (kind.startsWith('amenity:')) return 0.6;
    if (kind.startsWith('shop:')) return 0.6;
    if (kind.startsWith('highway:')) return 0.5;
    if (kind.startsWith('building:')) return 0.4;
    return 0.5;
  }

  /// Search: AND-intersection over query tokens, prefix matching on the last
  /// token, ranked by class weight and proximity to [near] (when given).
  List<GeoSearchResult> search(String query, {GeoPoint? near, int limit = 20}) {
    if (_raf == null) throw StateError('Geocoder not open');
    final tokens = tokenize(query);
    if (tokens.isEmpty) return const [];

    Set<int>? acc;
    for (int i = 0; i < tokens.length; i++) {
      final tok = tokens[i];
      final isLast = i == tokens.length - 1;
      Set<int> matched = {};
      var lb = _lowerBound(tok);
      if (lb >= 0) {
        for (int j = lb; j < _tokens.length; j++) {
          final t = _tokens[j];
          if (t == tok) {
            matched = _readPostings(j) ?? {};
            break;
          }
          if (!isLast || !t.startsWith(tok)) break;
          matched = {...matched, ...?_readPostings(j)};
        }
      }
      if (matched.isEmpty) return const [];
      acc = acc == null ? matched : acc.intersection(matched);
      if (acc.isEmpty) return const [];
    }

    final qLower = query.trim().toLowerCase();
    final results = <GeoSearchResult>[];
    for (final idx in acc!) {
      final e = _entries[idx];
      final name = _strings[e.nameRef];
      final kind = _strings[e.kindRef];
      final point = GeoPoint(e.latE7 / 1e7, e.lonE7 / 1e7);
      // Ranking: class weight (+ exact full-name bonus) plus a strong
      // proximity bonus when `near` is given (SPEC §4.4).
      var score = classWeight(kind);
      if (name.toLowerCase() == qLower) score *= 1.5;
      if (near != null) {
        final distM = point.distanceTo(near);
        score += 2.0 / (1.0 + distM / 100.0);
      }
      results.add(GeoSearchResult(name: name, kind: kind, point: point, score: score));
    }
    results.sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.name.compareTo(b.name);
    });
    return results.length > limit ? results.sublist(0, limit) : results;
  }
}
