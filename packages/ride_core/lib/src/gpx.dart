/// GPX 1.1 writer with Garmin TrackPointExtension v1 (SPEC §6).
///
/// TrackPointExtension carries hr/cad/atemp in schema order; power is
/// emitted as `ns3:power` (common industry practice) inside the same
/// extension element.
library;

import 'model.dart';
import 'xml_util.dart';

String toGpx(Ride r) {
  final b = StringBuffer();
  b.writeln('<?xml version="1.0" encoding="UTF-8"?>');
  b.writeln('<gpx version="1.1" creator="OpenRide"');
  b.writeln('  xmlns="http://www.topografix.com/GPX/1/1"');
  b.writeln('  xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"');
  b.writeln('  xmlns:ns3="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"');
  b.writeln('  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"');
  b.writeln('  xsi:schemaLocation="http://www.topografix.com/GPX/1/1'
      ' http://www.topografix.com/GPX/1/1/gpx.xsd'
      ' http://www.garmin.com/xmlschemas/TrackPointExtension/v1'
      ' http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd">');
  b.writeln('  <metadata><time>${isoUtc(r.started)}</time></metadata>');
  b.writeln('  <trk><name>OpenRide ${xmlEscape(r.id)}</name><type>cycling</type>');
  b.writeln('    <trkseg>');
  for (final p in r.points) {
    b.writeln('      <trkpt lat="${fmtNum(p.lat)}" lon="${fmtNum(p.lon)}">');
    if (p.ele != null) b.writeln('        <ele>${p.ele!.toStringAsFixed(1)}</ele>');
    b.writeln('        <time>${isoUtc(p.t)}</time>');
    final hasExt = p.hr != null || p.cad != null || p.temp != null || p.power != null;
    if (hasExt) {
      b.writeln('        <extensions>');
      b.writeln('          <gpxtpx:TrackPointExtension>');
      // TPX v1 element order: atemp, wtemp, depth, hr, cad
      if (p.temp != null) {
        b.writeln('            <gpxtpx:atemp>${p.temp!.toStringAsFixed(1)}</gpxtpx:atemp>');
      }
      if (p.hr != null) {
        b.writeln('            <gpxtpx:hr>${p.hr!.round()}</gpxtpx:hr>');
      }
      if (p.cad != null) {
        b.writeln('            <gpxtpx:cad>${p.cad!.round()}</gpxtpx:cad>');
      }
      if (p.power != null) {
        b.writeln('            <ns3:power>${p.power!.round()}</ns3:power>');
      }
      b.writeln('          </gpxtpx:TrackPointExtension>');
      b.writeln('        </extensions>');
    }
    b.writeln('      </trkpt>');
  }
  b.writeln('    </trkseg>');
  b.writeln('  </trk>');
  b.writeln('</gpx>');
  return b.toString();
}
