/// Offline bundle manager (SPEC §7 Settings/Data): lists, imports, activates
/// and deletes offline data bundles produced by osm_bundle_tool logic
/// (graph.bin + tiles.mbf + geocoder.bin + meta.json) under
/// `<docs>/bundles/<name>/`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared/shared.dart' show GeoBounds;

import 'isolates.dart';

/// Metadata about one bundle directory.
class BundleInfo {
  final String name; // directory name
  final String dir; // absolute path
  final GeoBounds? bounds;
  final DateTime? generatedAt;
  final int sourceBytes;
  final int sizeBytes; // total size of bundle files
  final bool hasGraph;
  final bool hasTiles;
  final bool hasGeocoder;

  const BundleInfo({
    required this.name,
    required this.dir,
    this.bounds,
    this.generatedAt,
    this.sourceBytes = 0,
    required this.sizeBytes,
    required this.hasGraph,
    required this.hasTiles,
    required this.hasGeocoder,
  });

  bool get isUsable => hasGraph && hasTiles && hasGeocoder;
}

class BundleManager extends ChangeNotifier {
  /// `<appDocuments>/bundles`
  final String rootDir;

  BundleManager(this.rootDir);

  bool _importing = false;
  String? _importingName;
  String? _lastImportError;

  bool get importing => _importing;
  String? get importingName => _importingName;
  String? get lastImportError => _lastImportError;

  Directory get _root => Directory(rootDir);

  /// All bundle directories that contain at least one artifact.
  List<BundleInfo> list() {
    final root = _root;
    if (!root.existsSync()) return const [];
    final out = <BundleInfo>[];
    for (final e in root.listSync()) {
      if (e is! Directory) continue;
      final info = _inspect(e);
      if (info != null) out.add(info);
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  BundleInfo? byName(String name) {
    final dir = Directory('$rootDir/$name');
    if (!dir.existsSync()) return null;
    return _inspect(dir);
  }

  BundleInfo? _inspect(Directory dir) {
    final name = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final graph = File('${dir.path}/graph.bin').existsSync();
    final tiles = File('${dir.path}/tiles.mbf').existsSync();
    final geocoder = File('${dir.path}/geocoder.bin').existsSync();
    if (!graph && !tiles && !geocoder) return null;

    GeoBounds? bounds;
    DateTime? generatedAt;
    var sourceBytes = 0;
    final metaFile = File('${dir.path}/meta.json');
    if (metaFile.existsSync()) {
      try {
        final j = jsonDecode(metaFile.readAsStringSync());
        if (j is Map) {
          final b = j['bounds'];
          if (b is Map) {
            bounds = GeoBounds(
              (b['minLat'] as num).toDouble(),
              (b['minLon'] as num).toDouble(),
              (b['maxLat'] as num).toDouble(),
              (b['maxLon'] as num).toDouble(),
            );
          }
          if (j['generatedAt'] is String) {
            generatedAt = DateTime.tryParse(j['generatedAt'] as String);
          }
          if (j['sourceBytes'] is num) {
            sourceBytes = (j['sourceBytes'] as num).toInt();
          }
        }
      } on Exception {
        // unreadable meta — still list the bundle
      }
    }

    var size = 0;
    for (final f in dir.listSync(recursive: true)) {
      if (f is File) {
        try {
          size += f.lengthSync();
        } on FileSystemException {
          // vanished mid-scan
        }
      }
    }
    return BundleInfo(
      name: name,
      dir: dir.path,
      bounds: bounds,
      generatedAt: generatedAt,
      sourceBytes: sourceBytes,
      sizeBytes: size,
      hasGraph: graph,
      hasTiles: tiles,
      hasGeocoder: geocoder,
    );
  }

  /// Builds a bundle from an .osm.pbf file. The build runs in a background
  /// isolate via `Isolate.run` inside [buildBundle]'s call site helper below.
  Future<BundleInfo> importPbf(String pbfPath) async {
    if (_importing) {
      throw StateError('an import is already running');
    }
    final src = File(pbfPath);
    if (!src.existsSync()) {
      throw ArgumentError('file not found: $pbfPath');
    }
    _importing = true;
    _importingName =
        pbfPath.split(Platform.pathSeparator).last.replaceAll('.osm.pbf', '');
    _lastImportError = null;
    notifyListeners();
    try {
      _root.createSync(recursive: true);
      final ts = DateTime.now().toUtc();
      final name =
          '${_importingName}-${ts.year}${_two(ts.month)}${_two(ts.day)}-${_two(ts.hour)}${_two(ts.minute)}${_two(ts.second)}';
      final outDir = '$rootDir/$name';
      await buildBundleInIsolate(pbfPath, outDir);
      // Remove a partially-built bundle when artifacts are missing.
      final info = _inspect(Directory(outDir));
      if (info == null || !info.isUsable) {
        throw const FormatException(
            'bundle build produced no usable artifacts');
      }
      return info;
    } catch (e) {
      _lastImportError = e.toString();
      rethrow;
    } finally {
      _importing = false;
      _importingName = null;
      notifyListeners();
    }
  }

  void delete(String name) {
    final dir = Directory('$rootDir/$name');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    notifyListeners();
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}
