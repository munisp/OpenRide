/// BRouter-style profile cost engine (SPEC §3.3).
///
/// BRouter computes edge cost = dist * factor, where factor is built
/// multiplicatively from way tags (highway class, surface, ...) and elevation
/// grade, plus a turn-cost model with an angle exponent. This is a faithful
/// port of that parameter model with defaults replicating `trekking.brf`
/// semantics.
library cost_profile;

import 'dart:math' as math;

import 'package:shared/shared.dart' show Profile;

/// Convenience view over an OSM way's tag map.
typedef OsmWayTags = Map<String, String>;

/// Cost model parameters. [trekkingProfile] etc. below provide per-profile
/// defaults; [CostProfile.trekking] replicates BRouter's trekking.brf gist.
class CostProfile {
  /// Cost multiplier per highway=* class. Values >= [forbiddenCost] mean the
  /// class is effectively closed to this profile.
  Map<String, double> highwayCost;

  /// Multiplicative modifier per surface=* value (1.0 = neutral).
  Map<String, double> surfaceCost;

  /// Turn cost model: cost = turnCostBase * (|angleDeg| / 180)^turnCostSlopeExp
  /// (BRouter turncost with angle exponent).
  double turnCostBase;
  double turnCostSlopeExp;

  /// Elevation model: for grade g (rise/run, percent = 100*g):
  ///  - uphill   (g%  > uphillCutoff):   factor *= 1 + 0.5 * (g% - uphillCutoff)^uphillSlopeExp
  ///  - downhill (g% < -downhillCutoff): factor *= 1 + 0.5 * (-g% - downhillCutoff)^downhillSlopeExp
  /// (BRouter uphillcost/downhillcost with cutoffs and exponents.)
  double uphillSlopeExp;
  double downhillSlopeExp;
  double downhillCutoff; // percent
  double uphillCutoff; // percent

  bool considerTurnRestrictions;

  /// One-off cost added per passed junction (BRouter initialcost), in
  /// equivalent meters of travel.
  double initialCost;

  /// Access mode of this profile: 'bicycle', 'foot' or 'motor_vehicle'.
  /// Drives the OSM access-tag hierarchy evaluation (BRouter priority:
  /// access < vehicle < bicycle, etc.).
  String accessMode;

  /// Base travel speed in m/s per highway class (time model); degraded by
  /// the cost factor at runtime.
  Map<String, double> baseSpeed;

  CostProfile({
    Map<String, double>? highwayCost,
    Map<String, double>? surfaceCost,
    this.turnCostBase = 10.0,
    this.turnCostSlopeExp = 1.3,
    this.uphillSlopeExp = 1.5,
    this.downhillSlopeExp = 1.5,
    this.downhillCutoff = 3.0,
    this.uphillCutoff = 1.0,
    this.considerTurnRestrictions = true,
    this.initialCost = 0.0,
    this.accessMode = 'bicycle',
    Map<String, double>? baseSpeed,
  })  : highwayCost = highwayCost ?? defaultHighwayCost(),
        surfaceCost = surfaceCost ?? defaultSurfaceCost(),
        baseSpeed = baseSpeed ?? defaultBaseSpeed();

  /// Cost factors >= this value mean "not passable" (BRouter treats huge
  /// costs as blocked; we use infinity for hard blocks and this threshold
  /// for soft ones).
  static const double forbiddenCost = 10000.0;

  static Map<String, double> defaultHighwayCost() => {
        'motorway': 1000.0,
        'motorway_link': 1000.0,
        'trunk': 50.0,
        'trunk_link': 20.0,
        'primary': 2.0,
        'primary_link': 2.0,
        'secondary': 1.6,
        'secondary_link': 1.6,
        'tertiary': 1.3,
        'tertiary_link': 1.3,
        'unclassified': 1.1,
        'residential': 1.0,
        'living_street': 1.0,
        'service': 1.2,
        'pedestrian': 1.2,
        'footway': 1.2,
        'steps': 3.0,
        'cycleway': 0.8,
        'path': 1.1,
        'track': 1.0,
        'bridleway': 1.4,
        'road': 1.5,
      };

  static Map<String, double> defaultSurfaceCost() => {
        'asphalt': 1.0,
        'paved': 1.0,
        'concrete': 1.0,
        'paving_stones': 1.1,
        'sett': 1.2,
        'compacted': 1.1,
        'fine_gravel': 1.15,
        'gravel': 1.4,
        'unpaved': 1.4,
        'ground': 1.5,
        'dirt': 1.5,
        'earth': 1.5,
        'grass': 1.8,
        'mud': 2.5,
        'sand': 3.0,
      };

  static Map<String, double> defaultBaseSpeed() => {
        // m/s nominal per class for a trekking bike (~ 18 km/h flat).
        'motorway': 8.3,
        'motorway_link': 8.3,
        'trunk': 7.0,
        'trunk_link': 7.0,
        'primary': 6.0,
        'primary_link': 6.0,
        'secondary': 5.8,
        'secondary_link': 5.8,
        'tertiary': 5.5,
        'tertiary_link': 5.5,
        'unclassified': 5.2,
        'residential': 5.0,
        'living_street': 4.5,
        'service': 4.5,
        'pedestrian': 3.5,
        'footway': 3.5,
        'steps': 1.5,
        'cycleway': 5.5,
        'path': 4.0,
        'track': 4.5,
        'bridleway': 3.5,
        'road': 5.0,
      };

  /// BRouter trekking.brf replication.
  factory CostProfile.trekking() => CostProfile();

  /// Fastbike: prefers bigger, smoother roads; stiffer turn penalty.
  factory CostProfile.fastbike() {
    final p = CostProfile();
    p.highwayCost['primary'] = 1.1;
    p.highwayCost['primary_link'] = 1.1;
    p.highwayCost['secondary'] = 1.0;
    p.highwayCost['secondary_link'] = 1.0;
    p.highwayCost['tertiary'] = 1.0;
    p.highwayCost['tertiary_link'] = 1.0;
    p.highwayCost['unclassified'] = 1.1;
    p.highwayCost['residential'] = 1.2;
    p.highwayCost['cycleway'] = 1.0;
    p.highwayCost['path'] = 3.0;
    p.highwayCost['track'] = 2.0;
    p.highwayCost['footway'] = 3.0;
    p.highwayCost['pedestrian'] = 3.0;
    p.highwayCost['steps'] = 1000.0;
    p.highwayCost['bridleway'] = 4.0;
    p.turnCostBase = 20.0;
    p.turnCostSlopeExp = 1.5;
    for (final k in p.baseSpeed.keys.toList()) {
      p.baseSpeed[k] = p.baseSpeed[k]! * 1.3; // ~ faster rider
    }
    return p;
  }

  /// Roadbike: paved only, big roads cheap, unpaved very expensive.
  factory CostProfile.roadbike() {
    final p = CostProfile.fastbike();
    p.surfaceCost = Map<String, double>.from(p.surfaceCost)
      ..['gravel'] = 5.0
      ..['unpaved'] = 5.0
      ..['ground'] = 8.0
      ..['dirt'] = 8.0
      ..['earth'] = 8.0
      ..['grass'] = 20.0
      ..['sand'] = 1000.0
      ..['mud'] = 1000.0;
    return p;
  }

  /// MTB: unpaved cheap, technical ok.
  factory CostProfile.mtb() {
    final p = CostProfile();
    p.highwayCost['track'] = 0.9;
    p.highwayCost['path'] = 0.9;
    p.highwayCost['bridleway'] = 1.0;
    p.highwayCost['primary'] = 3.0;
    p.highwayCost['secondary'] = 2.0;
    p.surfaceCost = Map<String, double>.from(p.surfaceCost)
      ..['gravel'] = 1.0
      ..['unpaved'] = 1.0
      ..['ground'] = 1.0
      ..['dirt'] = 1.0
      ..['earth'] = 1.0
      ..['grass'] = 1.2
      ..['sand'] = 1.8
      ..['mud'] = 1.8;
    return p;
  }

  /// Car (fast): motor_vehicle access, trunk/motorway preferred.
  factory CostProfile.carFast() {
    final p = CostProfile(accessMode: 'motor_vehicle');
    p.highwayCost = {
      'motorway': 0.8,
      'motorway_link': 0.9,
      'trunk': 0.9,
      'trunk_link': 1.0,
      'primary': 1.0,
      'primary_link': 1.1,
      'secondary': 1.2,
      'secondary_link': 1.3,
      'tertiary': 1.4,
      'tertiary_link': 1.5,
      'unclassified': 1.8,
      'residential': 2.0,
      'living_street': 3.0,
      'service': 2.5,
      'road': 2.0,
    };
    p.turnCostBase = 30.0;
    p.turnCostSlopeExp = 1.5;
    p.baseSpeed = {
      'motorway': 33.0,
      'motorway_link': 20.0,
      'trunk': 27.0,
      'trunk_link': 18.0,
      'primary': 22.0,
      'primary_link': 15.0,
      'secondary': 18.0,
      'secondary_link': 14.0,
      'tertiary': 15.0,
      'tertiary_link': 12.0,
      'unclassified': 13.0,
      'residential': 11.0,
      'living_street': 3.0,
      'service': 8.0,
      'road': 15.0,
    };
    return p;
  }

  /// Car (eco): like carFast but shorter/calmer routing via minor roads is
  /// less penalized (models fuel-efficient avoidance of motorway bursts).
  factory CostProfile.carEco() {
    final p = CostProfile.carFast();
    p.highwayCost['motorway'] = 1.0;
    p.highwayCost['motorway_link'] = 1.1;
    p.highwayCost['trunk'] = 1.0;
    p.highwayCost['trunk_link'] = 1.1;
    p.highwayCost['primary'] = 1.0;
    p.highwayCost['secondary'] = 1.0;
    p.highwayCost['tertiary'] = 1.0;
    for (final k in p.baseSpeed.keys.toList()) {
      p.baseSpeed[k] = p.baseSpeed[k]! * 0.9;
    }
    return p;
  }

  /// Foot profile.
  factory CostProfile.foot() {
    final p = CostProfile(accessMode: 'foot');
    p.highwayCost = {
      'motorway': forbiddenCost,
      'motorway_link': forbiddenCost,
      'trunk': 10.0,
      'trunk_link': 10.0,
      'primary': 2.5,
      'primary_link': 2.5,
      'secondary': 2.0,
      'secondary_link': 2.0,
      'tertiary': 1.6,
      'tertiary_link': 1.6,
      'unclassified': 1.3,
      'residential': 1.2,
      'living_street': 1.0,
      'service': 1.2,
      'pedestrian': 0.8,
      'footway': 0.8,
      'steps': 1.0,
      'cycleway': 1.0,
      'path': 0.9,
      'track': 1.0,
      'bridleway': 1.0,
      'road': 1.5,
    };
    p.turnCostBase = 0.0; // pedestrians ignore turn effort
    final s = <String, double>{};
    for (final k in p.highwayCost.keys) {
      s[k] = 1.4; // 5 km/h
    }
    p.baseSpeed = s;
    return p;
  }

  /// Profile instance for a SPEC §2 [Profile] enum value.
  static CostProfile forProfile(Profile profile) {
    switch (profile) {
      case Profile.trekking:
        return CostProfile.trekking();
      case Profile.fastbike:
        return CostProfile.fastbike();
      case Profile.roadbike:
        return CostProfile.roadbike();
      case Profile.mtb:
        return CostProfile.mtb();
      case Profile.carFast:
        return CostProfile.carFast();
      case Profile.carEco:
        return CostProfile.carEco();
      case Profile.foot:
        return CostProfile.foot();
    }
  }

  /// All seven profiles, for iteration in tests/tools.
  static List<CostProfile> all() =>
      Profile.values.map(forProfile).toList(growable: false);
}

/// BRouter access-hierarchy evaluation.
///
/// Priority (least to most specific, later wins) for mode 'bicycle':
///   access < vehicle < bicycle
/// for mode 'foot': access < foot
/// for mode 'motor_vehicle': access < vehicle < motor_vehicle
/// Plus modal defaults (motorway forbids bicycle/foot unless explicitly
/// allowed, footway forbids motor vehicles, ...).
bool isAccessible(OsmWayTags tags, String accessMode) {
  // Default by highway class.
  final highway = tags['highway'] ?? '';
  var allowed = true;
  if (accessMode == 'bicycle') {
    if ((highway == 'motorway' || highway == 'motorway_link') &&
        tags['bicycle'] == null) {
      allowed = false;
    }
  } else if (accessMode == 'foot') {
    if ((highway == 'motorway' || highway == 'motorway_link') &&
        tags['foot'] == null) {
      allowed = false;
    }
  } else {
    // motor vehicle
    const nonMotor = {
      'footway',
      'pedestrian',
      'steps',
      'cycleway',
      'path',
      'bridleway',
      'track',
    };
    if (nonMotor.contains(highway) &&
        tags['motor_vehicle'] == null &&
        tags['motorcar'] == null &&
        tags['vehicle'] == null &&
        tags['access'] == null) {
      allowed = false;
    }
  }

  if (tags['motorroad'] == 'yes' && accessMode != 'motor_vehicle') {
    allowed = false;
  }

  const chain = {
    'bicycle': ['access', 'vehicle', 'bicycle'],
    'foot': ['access', 'foot'],
    'motor_vehicle': ['access', 'vehicle', 'motor_vehicle', 'motorcar'],
  };
  for (final key in chain[accessMode]!) {
    final v = tags[key];
    if (v != null) allowed = _valueAllows(v);
  }
  return allowed;
}

bool _valueAllows(String v) {
  switch (v) {
    case 'no':
    case 'private':
    case 'agricultural':
    case 'forestry':
    case 'delivery':
      return false;
    default:
      // yes, designated, permissive, destination, customers, ...
      return true;
  }
}

/// BRouter multiplicative way-cost model: factor = highwayCost[highway] *
/// surfaceCost[surface] (when the surface tag is known) * initialcost is
/// applied per junction at routing time, not here. Returns
/// [double.infinity] when the way is closed to the profile.
double edgeCostFactor(CostProfile p, OsmWayTags tags) {
  if (!isAccessible(tags, p.accessMode)) return double.infinity;
  final highway = tags['highway'];
  if (highway == null) return double.infinity;
  var factor = p.highwayCost[highway];
  if (factor == null) {
    // Unknown highway class: routable but neutral, like BRouter's fallback.
    factor = 2.0;
  }
  final surface = tags['surface'];
  if (surface != null) {
    final s = p.surfaceCost[surface];
    if (s != null) factor *= s;
  }
  if (factor >= CostProfile.forbiddenCost) return double.infinity;
  return factor;
}

/// BRouter turn-cost model with angle exponent.
/// [signedAngleDeg] in (-180,180]; 0 = straight on.
double turnCost(CostProfile p, double signedAngleDeg) {
  if (p.turnCostBase <= 0) return 0;
  final a = signedAngleDeg.abs() / 180.0;
  return p.turnCostBase * math.pow(a, p.turnCostSlopeExp).toDouble();
}

/// BRouter elevation cost multiplier for grade (rise/run). See [CostProfile]
/// for the formula; grade is converted to percent internally.
double elevationCostFactor(CostProfile p, double grade) {
  final gPct = grade * 100.0;
  if (gPct > p.uphillCutoff) {
    return 1.0 +
        0.5 * math.pow(gPct - p.uphillCutoff, p.uphillSlopeExp).toDouble();
  }
  if (gPct < -p.downhillCutoff) {
    return 1.0 +
        0.5 * math.pow(-gPct - p.downhillCutoff, p.downhillSlopeExp).toDouble();
  }
  return 1.0;
}
