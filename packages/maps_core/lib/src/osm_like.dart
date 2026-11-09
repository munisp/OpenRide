/// Minimal OSM-like node/way stream interface (SPEC §4.4 note), consumed by the
/// tile builder (§4.1) and the geocoder (§4.4). The bundle tool adapts its PBF
/// reader to this interface; tests use [MemoryOsm].
library;

class OsmLikeNode {
  final int id;
  final double lat, lon;
  final Map<String, String> tags;
  const OsmLikeNode(this.id, this.lat, this.lon, [this.tags = const {}]);
}

class OsmLikeWay {
  final int id;
  final List<int> refs;
  final Map<String, String> tags;
  const OsmLikeWay(this.id, this.refs, [this.tags = const {}]);

  /// Closed way (first ref == last ref) — candidate polygon.
  bool get isClosed => refs.length >= 4 && refs.first == refs.last;
}

/// Stream-like access to OSM nodes and ways. Iterables may be lazy.
abstract class OsmLike {
  Iterable<OsmLikeNode> get nodes;
  Iterable<OsmLikeWay> get ways;
}

/// Simple in-memory [OsmLike] (used by tests and small extracts).
class MemoryOsm implements OsmLike {
  final List<OsmLikeNode> nodeList;
  final List<OsmLikeWay> wayList;
  const MemoryOsm({this.nodeList = const [], this.wayList = const []});

  @override
  Iterable<OsmLikeNode> get nodes => nodeList;
  @override
  Iterable<OsmLikeWay> get ways => wayList;
}
