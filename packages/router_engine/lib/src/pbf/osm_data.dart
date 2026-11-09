/// OSM data model (SPEC §3.1).
library osm_data;

class OsmNode {
  final int id;
  final double lat;
  final double lon;
  final Map<String, String> tags;

  OsmNode(this.id, this.lat, this.lon, [Map<String, String>? tags])
      : tags = tags ?? const {};

  @override
  String toString() => 'OsmNode($id, $lat, $lon)';
}

class OsmWay {
  final int id;
  final List<int> nodeRefs;
  final Map<String, String> tags;

  OsmWay(this.id, this.nodeRefs, [Map<String, String>? tags])
      : tags = tags ?? const {};

  @override
  String toString() => 'OsmWay($id, ${nodeRefs.length} refs)';
}

/// Restriction kinds from the OSM `restriction=*` tag.
enum RestrictionType {
  noLeftTurn,
  noRightTurn,
  noStraightOn,
  noUTurn,
  noEntry,
  onlyLeftTurn,
  onlyRightTurn,
  onlyStraightOn,
}

RestrictionType? restrictionTypeFromString(String s) {
  switch (s) {
    case 'no_left_turn':
      return RestrictionType.noLeftTurn;
    case 'no_right_turn':
      return RestrictionType.noRightTurn;
    case 'no_straight_on':
      return RestrictionType.noStraightOn;
    case 'no_u_turn':
      return RestrictionType.noUTurn;
    case 'no_entry':
      return RestrictionType.noEntry;
    case 'only_left_turn':
      return RestrictionType.onlyLeftTurn;
    case 'only_right_turn':
      return RestrictionType.onlyRightTurn;
    case 'only_straight_on':
    case 'only_follow':
      return RestrictionType.onlyStraightOn;
    default:
      return null;
  }
}

/// A via-node turn restriction (SPEC §3.1). Via-way restrictions are not
/// representable in this model and are skipped by the parser.
class TurnRestriction {
  final int fromWay;
  final int viaNode;
  final int toWay;
  final RestrictionType type;

  const TurnRestriction(this.fromWay, this.viaNode, this.toWay, this.type);

  /// True for `no_*` restrictions (forbid the specific maneuver).
  bool get isProhibitive =>
      type == RestrictionType.noLeftTurn ||
      type == RestrictionType.noRightTurn ||
      type == RestrictionType.noStraightOn ||
      type == RestrictionType.noUTurn ||
      type == RestrictionType.noEntry;

  @override
  String toString() =>
      'TurnRestriction($type from=$fromWay via=$viaNode to=$toWay)';
}

/// Parsed contents of an .osm.pbf file.
class OsmData {
  final Map<int, OsmNode> nodes;
  final Map<int, OsmWay> ways;
  final List<TurnRestriction> restrictions;

  OsmData({
    Map<int, OsmNode>? nodes,
    Map<int, OsmWay>? ways,
    List<TurnRestriction>? restrictions,
  })  : nodes = nodes ?? <int, OsmNode>{},
        ways = ways ?? <int, OsmWay>{},
        restrictions = restrictions ?? <TurnRestriction>[];

  int get nodeCount => nodes.length;
  int get wayCount => ways.length;
}
