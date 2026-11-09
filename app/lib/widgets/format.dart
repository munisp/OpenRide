/// Formatting + icon helpers shared by the screens.
library;

import 'package:flutter/material.dart';
import 'package:nav_engine/nav_engine.dart' as nav;
import 'package:shared/shared.dart' show Profile;

String fmtDistance(double m) {
  if (m < 1000) return '${m.round()} m';
  final km = m / 1000.0;
  return km < 100 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
}

String fmtDuration(double seconds) {
  final s = seconds.round();
  final h = s ~/ 3600;
  final min = (s % 3600) ~/ 60;
  final sec = s % 60;
  if (h > 0) return '$h:${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  return '${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

/// "14:32" style arrival/ETA rendering.
String fmtEta(double seconds) {
  if (seconds <= 0 || !seconds.isFinite) return '–';
  if (seconds >= 36000) return '>10 h';
  return fmtDuration(seconds);
}

String fmtSpeed(double mps) => (mps * 3.6).toStringAsFixed(1);

String fmtBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String profileLabel(Profile p) => switch (p) {
      Profile.trekking => 'Trekking bike',
      Profile.fastbike => 'Fast bike',
      Profile.roadbike => 'Road bike',
      Profile.mtb => 'MTB',
      Profile.carFast => 'Car (fast)',
      Profile.carEco => 'Car (eco)',
      Profile.foot => 'Foot',
    };

IconData maneuverIcon(nav.ManeuverType t) => switch (t) {
      nav.ManeuverType.depart => Icons.trip_origin,
      nav.ManeuverType.turnLeft => Icons.turn_left,
      nav.ManeuverType.turnRight => Icons.turn_right,
      nav.ManeuverType.slightLeft => Icons.turn_slight_left,
      nav.ManeuverType.slightRight => Icons.turn_slight_right,
      nav.ManeuverType.sharpLeft => Icons.keyboard_double_arrow_left,
      nav.ManeuverType.sharpRight => Icons.keyboard_double_arrow_right,
      nav.ManeuverType.uturn => Icons.u_turn_left,
      nav.ManeuverType.straight => Icons.straight,
      nav.ManeuverType.roundaboutEnter => Icons.rotate_right,
      nav.ManeuverType.roundaboutExit => Icons.rotate_right,
      nav.ManeuverType.arrive => Icons.flag,
    };
