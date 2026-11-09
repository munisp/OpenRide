/// LocationAdapter — wraps `geolocator` behind a small app-local interface
/// (SPEC §7). Handles the runtime permission flow and exposes a normalized
/// fix stream in WGS-84 degrees / m/s / meters.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart' as geo;

/// A single GNSS fix, normalized for the app and the engine packages.
class LocationFix {
  final double lat;
  final double lon;

  /// Meters above the WGS-84 ellipsoid when available (GPS altitude).
  final double? altitudeM;

  /// Horizontal accuracy in meters (null/NaN-safe).
  final double? accuracyM;

  /// Ground speed in m/s (null when the platform reports none).
  final double? speedMps;

  /// Course over ground in degrees 0..360 (null when unsupported).
  final double? headingDeg;

  /// Fix timestamp (device clock).
  final DateTime t;

  const LocationFix({
    required this.lat,
    required this.lon,
    required this.t,
    this.altitudeM,
    this.accuracyM,
    this.speedMps,
    this.headingDeg,
  });
}

enum LocationPermissionState { granted, denied, deniedForever, serviceDisabled }

/// Small interface the rest of the app depends on; the only implementation
/// wraps geolocator, but tests / previews can substitute a fake.
abstract class LocationAdapter {
  Future<LocationPermissionState> ensurePermission();
  Stream<LocationFix> fixes();
  Future<LocationFix?> current();
}

class GeolocatorLocationAdapter implements LocationAdapter {
  /// One shared stream for the whole app (geolocator opens a single platform
  /// subscription; multiple Dart listeners share it via broadcast).
  Stream<LocationFix>? _shared;

  @override
  Future<LocationPermissionState> ensurePermission() async {
    final serviceOn = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceOn) return LocationPermissionState.serviceDisabled;
    var perm = await geo.Geolocator.checkPermission();
    if (perm == geo.LocationPermission.denied) {
      perm = await geo.Geolocator.requestPermission();
    }
    switch (perm) {
      case geo.LocationPermission.always:
      case geo.LocationPermission.whileInUse:
        return LocationPermissionState.granted;
      case geo.LocationPermission.deniedForever:
        return LocationPermissionState.deniedForever;
      case geo.LocationPermission.denied:
        return LocationPermissionState.denied;
      case geo.LocationPermission.unableToDetermine:
        return LocationPermissionState.denied;
    }
  }

  @override
  Stream<LocationFix> fixes() {
    return _shared ??= geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).map(_toFix).asBroadcastStream();
  }

  @override
  Future<LocationFix?> current() async {
    final perm = await ensurePermission();
    if (perm != LocationPermissionState.granted) return null;
    try {
      return _toFix(await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 10),
        ),
      ));
    } on TimeoutException {
      try {
        final last = await geo.Geolocator.getLastKnownPosition();
        return last == null ? null : _toFix(last);
      } on Exception {
        return null;
      }
    } on Exception {
      return null;
    }
  }

  LocationFix _toFix(geo.Position p) {
    double? sane(double v, {double? invalidBelow}) {
      if (v.isNaN || !v.isFinite) return null;
      if (invalidBelow != null && v < invalidBelow) return null;
      return v;
    }

    final heading = sane(p.heading, invalidBelow: 0.0);
    return LocationFix(
      lat: p.latitude,
      lon: p.longitude,
      t: p.timestamp,
      altitudeM: sane(p.altitude),
      accuracyM: sane(p.accuracy, invalidBelow: 0.0),
      speedMps: sane(p.speed, invalidBelow: 0.0),
      // geolocator reports -1/NaN for unsupported headings.
      headingDeg: heading != null && heading <= 360.0 ? heading : null,
    );
  }
}
