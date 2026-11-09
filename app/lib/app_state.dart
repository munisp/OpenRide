/// AppState — the app-wide service locator / aggregate state (SPEC §7.4:
/// simple ChangeNotifier approach, no external state-management packages).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:maps_core/maps_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ride_core/ride_core.dart' show RideStore;
import 'package:router_engine/router_engine.dart' show RouteResult, Profile;

import 'data/bundle_manager.dart';
import 'data/isolates.dart';
import 'data/navigation_controller.dart';
import 'data/recording_controller.dart';
import 'map/tile_source.dart';
import 'platform/barometer_adapter.dart';
import 'platform/ble_sensor_adapter.dart';
import 'platform/location_adapter.dart';
import 'platform/tts_adapter.dart';
import 'settings.dart';

class AppState extends ChangeNotifier {
  AppState._();

  static final AppState instance = AppState._();

  late final AppSettings settings;
  late final BundleManager bundles;
  late final MapTileSource tiles;
  late final RouterService router;

  late final LocationAdapter location;
  late final BleSensorAdapter ble;
  late final BarometerAdapter baro;
  late final TtsAdapter tts;

  late final RideStore rideStore;
  late final RecordingController recording;
  late final NavigationController navigation;

  /// Offline geocoder for the active bundle (null when none active).
  Geocoder? geocoder;

  bool _initialized = false;
  bool get initialized => _initialized;

  late final String documentsDir;

  /// Bottom-nav tab selection (0..4) so screens can switch tabs
  /// (e.g. planner → navigate) without extra packages.
  final ValueNotifier<int> selectedTab = ValueNotifier<int>(0);

  void selectTab(int index) => selectedTab.value = index;

  Future<void> init() async {
    if (_initialized) return;
    final docs = await getApplicationDocumentsDirectory();
    documentsDir = docs.path;
    Directory('${docs.path}/bundles').createSync(recursive: true);

    settings = AppSettings(docs.path);
    await settings.load();

    bundles = BundleManager('${docs.path}/bundles');
    tiles = MapTileSource();
    router = RouterService();

    location = GeolocatorLocationAdapter();
    ble = FbpBleSensorAdapter();
    baro = SensorsPlusBarometerAdapter();
    tts = FlutterTtsAdapter(enabled: settings.voiceEnabled);

    rideStore = RideStore('${docs.path}/rides_store');
    recording = RecordingController(
      location: location,
      ble: ble,
      baro: baro,
      store: rideStore,
    );
    navigation = NavigationController(
      location: location,
      tts: tts,
      router: router,
    );

    settings.addListener(() {
      tts.enabled = settings.voiceEnabled;
      tiles.setDark(settings.darkMap);
    });
    tiles.setDark(settings.darkMap);

    await activateBundle(settings.activeBundle);
    _initialized = true;
    notifyListeners();
  }

  /// The currently active bundle (null when none has been imported yet).
  BundleInfo? get activeBundle =>
      settings.activeBundle == null ? null : bundles.byName(settings.activeBundle!);

  /// Opens the bundle's tile store + geocoder and pre-loads the routing
  /// graph used by navigation reroutes.
  Future<void> activateBundle(String? name) async {
    geocoder?.close();
    geocoder = null;
    tiles.close();
    if (name != null) {
      final info = bundles.byName(name);
      if (info != null && info.isUsable) {
        try {
          tiles.open('${info.dir}/tiles.mbf');
        } on Exception {
          // corrupt tile store; leave map closed
        }
        try {
          final g = Geocoder()..open('${info.dir}/geocoder.bin');
          geocoder = g;
        } on Exception {
          geocoder = null;
        }
        try {
          await router.load(info.dir);
        } on Exception {
          // graph load failed; routing will surface errors when used
        }
        settings.setActiveBundle(name);
      } else {
        settings.setActiveBundle(null);
      }
    } else {
      settings.setActiveBundle(null);
    }
    notifyListeners();
  }

  Future<void> deleteBundle(String name) async {
    final wasActive = settings.activeBundle == name;
    if (wasActive) await activateBundle(null);
    bundles.delete(name);
    notifyListeners();
  }

  /// Called by the planner when a route was computed and the user starts
  /// guidance. Returns false when navigation could not start.
  Future<bool> startNavigation(RouteResult route, Profile profile) {
    return navigation.start(route, profile);
  }
}
