/// Garmin Training Center XML (TCX) v2 writer (SPEC §6).
///
/// Single Activity Sport="Biking", one Lap covering the whole ride,
/// Track/Trackpoint elements in schema order, Watts via the
/// ActivityExtension v2 TPX extension.
library;

import 'model.dart';
import 'xml_util.dart';

String toTcx(Ride r) {
  final s = r.stats;
  final b = StringBuffer();
  b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  b.writeln('<TrainingCenterDatabase'
      ' xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"'
      ' xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
      ' xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2"'
      ' xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2'
      ' http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">');
  b.writeln('  <Activities>');
  b.writeln('    <Activity Sport="Biking">');
  b.writeln('      <Id>${isoUtc(r.started)}</Id>');

  final totalS = (s['totalTimeS'] ?? 0).toDouble();
  final dist = (s['distanceM'] ?? 0).toDouble();
  final maxSpd = (s['maxSpeedMps'] ?? 0).toDouble();
  final avgSpd = (s['avgMovingSpeedMps'] ?? 0).toDouble();
  final kcal = (s['calories'] ?? 0).toDouble();
  final avgHr = (s['avgHr'] ?? 0).toDouble();
  final maxHr = (s['maxHr'] ?? 0).toDouble();
  final avgCad = (s['avgCadence'] ?? 0).toDouble();

  b.writeln('      <Lap StartTime="${isoUtc(r.started)}">');
  b.writeln('        <TotalTimeSeconds>${totalS.toStringAsFixed(3)}</TotalTimeSeconds>');
  b.writeln('        <DistanceMeters>${dist.toStringAsFixed(2)}</DistanceMeters>');
  b.writeln('        <MaximumSpeed>${maxSpd.toStringAsFixed(3)}</MaximumSpeed>');
  b.writeln('        <Calories>${kcal.round()}</Calories>');
  if (avgHr > 0) {
    b.writeln('        <AverageHeartRateBpm><Value>${avgHr.round()}</Value>'
        '</AverageHeartRateBpm>');
  }
  if (maxHr > 0) {
    b.writeln('        <MaximumHeartRateBpm><Value>${maxHr.round()}</Value>'
        '</MaximumHeartRateBpm>');
  }
  b.writeln('        <Intensity>Active</Intensity>');
  if (avgCad > 0) b.writeln('        <Cadence>${avgCad.round()}</Cadence>');
  b.writeln('        <TriggerMethod>Manual</TriggerMethod>');
  b.writeln('        <Track>');

  final cumDistances = cumulativeDistances(r.points, pauses: r.pauses);
  for (var i = 0; i < r.points.length; i++) {
    final p = r.points[i];
    final cumDist = cumDistances[i];
    b.writeln('          <Trackpoint>');
    b.writeln('            <Time>${isoUtc(p.t)}</Time>');
    b.writeln('            <Position>');
    b.writeln('              <LatitudeDegrees>${fmtNum(p.lat)}</LatitudeDegrees>');
    b.writeln('              <LongitudeDegrees>${fmtNum(p.lon)}</LongitudeDegrees>');
    b.writeln('            </Position>');
    if (p.ele != null) {
      b.writeln('            <AltitudeMeters>${p.ele!.toStringAsFixed(1)}</AltitudeMeters>');
    }
    b.writeln('            <DistanceMeters>${cumDist.toStringAsFixed(2)}</DistanceMeters>');
    if (p.hr != null) {
      b.writeln('            <HeartRateBpm><Value>${p.hr!.round()}</Value></HeartRateBpm>');
    }
    if (p.cad != null) b.writeln('            <Cadence>${p.cad!.round()}</Cadence>');
    if (p.power != null || p.speed != null) {
      b.writeln('            <Extensions><ns3:TPX>');
      if (p.speed != null) {
        b.writeln('              <ns3:Speed>${p.speed!.toStringAsFixed(3)}</ns3:Speed>');
      }
      if (p.power != null) {
        b.writeln('              <ns3:Watts>${p.power!.round()}</ns3:Watts>');
      }
      b.writeln('            </ns3:TPX></Extensions>');
    }
    b.writeln('          </Trackpoint>');
  }
  b.writeln('        </Track>');
  b.writeln('        <Extensions><ns3:LX>');
  b.writeln('          <ns3:AvgSpeed>${avgSpd.toStringAsFixed(3)}</ns3:AvgSpeed>');
  b.writeln('        </ns3:LX></Extensions>');
  b.writeln('      </Lap>');
  b.writeln('    </Activity>');
  b.writeln('  </Activities>');
  b.writeln('</TrainingCenterDatabase>');
  return b.toString();
}
