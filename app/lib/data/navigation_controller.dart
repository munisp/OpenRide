/// NavigationController — owns a nav_engine Navigator session so navigation
/// survives tab switches (SPEC §7 Navigate screen). Streams position updates
/// into the engine, drains voice prompts into the TTS adapter, and exposes
/// the latest NavState for the UI.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nav_engine/nav_engine.dart' as nav;
import 'package:router_engine/router_engine.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../platform/location_adapter.dart';
import '../platform/tts_adapter.dart';
import 'isolates.dart';

class NavigationController extends ChangeNotifier {
  final LocationAdapter location;
  final TtsAdapter tts;
  final RouterService router;

  NavigationController({
    required this.location,
    required this.tts,
    required this.router,
  });

  nav.Navigator? _navigator;
  StreamSubscription<LocationFix>? _sub;

  nav.NavState? state;
  GeoPoint? position;
  double? headingDeg;
  bool starting = false;
  String? startError;

  /// Route currently being navigated (changes after automatic reroutes).
  RouteResult? get currentRoute => _navigator?.currentRoute;

  Profile? profile;
  bool get active => _navigator != null;

  /// True when the last maneuver was consumed and we're near the destination.
  bool get arrived =>
      state != null && state!.next == null && state!.remainingM < 25.0;

  Future<bool> start(RouteResult route, Profile p) async {
    if (starting) return false;
    starting = true;
    startError = null;
    notifyListeners();
    try {
      if (!router.isLoaded) {
        startError = 'No routing graph loaded — activate an offline bundle.';
        return false;
      }
      final perm = await location.ensurePermission();
      if (perm != LocationPermissionState.granted) {
        startError = 'Location permission required for navigation.';
        return false;
      }
      profile = p;
      _navigator = nav.Navigator(route, router.engine, p);
      state = null;
      _sub = location.fixes().listen(_onFix, onError: (Object _) {});
      await WakelockPlus.enable();
      final maneuvers = nav.buildManeuvers(route);
      final depart = maneuvers.isEmpty ? null : maneuvers.first;
      tts.speak(depart != null && depart.type == nav.ManeuverType.depart
          ? depart.instruction
          : 'Route started');
      return true;
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  void _onFix(LocationFix fix) {
    final n = _navigator;
    if (n == null) return;
    position = GeoPoint(fix.lat, fix.lon);
    headingDeg = fix.headingDeg;
    state = n.update(
      position!,
      fix.speedMps ?? 0.0,
      fix.headingDeg ?? double.nan,
    );
    for (final prompt in n.drainVoicePrompts()) {
      tts.speak(prompt);
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _navigator = null;
    state = null;
    position = null;
    headingDeg = null;
    await tts.stop();
    await WakelockPlus.disable();
    notifyListeners();
  }

  /// Rerouting happens inside nav_engine on location updates; this exposes
  /// the flag from the latest state for the UI indicator.
  bool get rerouting => state?.rerouting ?? false;
}
