/// BarometerAdapter — wraps `sensors_plus` ambient pressure and converts to
/// elevation via the international barometric formula (SPEC §7).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

/// Standard sea-level pressure reference (hPa) when no calibration is known.
const double kSeaLevelPressureHPa = 1013.25;

/// Converts ambient pressure [hPa] to altitude in meters using the
/// international barometric formula (ISA troposphere).
double pressureToElevationM(double hPa, {double referenceHPa = kSeaLevelPressureHPa}) {
  if (hPa <= 0) return 0;
  return 44330.0 * (1.0 - math.pow(hPa / referenceHPa, 1.0 / 5.255));
}

abstract class BarometerAdapter {
  /// Elevation in meters derived from ambient pressure.
  Stream<double> elevationM();

  /// Raw ambient pressure in hPa.
  Stream<double> pressureHPa();
}

class SensorsPlusBarometerAdapter implements BarometerAdapter {
  Stream<double>? _pressure;

  @override
  Stream<double> pressureHPa() {
    // Broadcast so multiple consumers (recorder, UI) can attach; onError is
    // handled by subscribers (devices without a barometer never emit).
    return _pressure ??=
        barometerEvents.map((e) => e.pressure).asBroadcastStream();
  }

  @override
  Stream<double> elevationM() => pressureHPa().map(pressureToElevationM);
}
