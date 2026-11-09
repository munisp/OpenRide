/// Map/Planner screen (SPEC §7): offline map, long-press waypoint entry,
/// profile picker (all 7 profiles), isolate-based routing, route polyline
/// overlay, maneuver list, geocoder search.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maps_core/maps_core.dart';
import 'package:nav_engine/nav_engine.dart' as nav;
import 'package:router_engine/router_engine.dart';

import '../app_state.dart';
import '../data/isolates.dart';
import '../map/offline_map.dart';
import '../widgets/format.dart';

class MapPlannerScreen extends StatefulWidget {
  const MapPlannerScreen({super.key});

  @override
  State<MapPlannerScreen> createState() => _MapPlannerScreenState();
}

class _MapPlannerScreenState extends State<MapPlannerScreen> {
  final OfflineMapController _map = OfflineMapController();
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  GeoPoint? _start;
  GeoPoint? _end;
  final List<GeoPoint> _via = [];

  late Profile _profile;
  RouteResult? _route;
  List<nav.Maneuver> _maneuvers = const [];
  bool _routing = false;
  String? _routeError;

  List<GeoSearchResult> _results = const [];
  bool _searching = false;
  bool _locatedOnce = false;

  AppState get _app => AppState.instance;

  @override
  void initState() {
    super.initState();
    _map.tileSource = _app.tiles;
    _profile = _app.settings.defaultProfile;
    _syncMarkers();
    _locateInitially();
  }

  Future<void> _locateInitially() async {
    final fix = await _app.location.current();
    if (fix == null || _locatedOnce || !mounted) return;
    _locatedOnce = true;
    // Only jump to GPS when it is plausibly inside the bundle coverage.
    final cov = _app.tiles.coverage;
    final p = GeoPoint(fix.lat, fix.lon);
    if (cov == null || cov.contains(p)) {
      _map.centerOn(p);
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ search

  void _onSearchChanged(String q) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _runSearch(q);
    });
  }

  void _runSearch(String q) {
    final geocoder = _app.geocoder;
    if (geocoder == null || q.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      final r = geocoder.search(q, near: _map.center, limit: 12);
      if (mounted) {
        setState(() {
          _results = r;
          _searching = false;
        });
      }
    } on StateError {
      if (mounted) setState(() => _searching = false);
    }
  }

  // --------------------------------------------------------------- waypoints

  void _syncMarkers() {
    final markers = <MapMarker>[
      if (_start != null) MapMarker(_start!, MapMarkerKind.start),
      for (var i = 0; i < _via.length; i++)
        MapMarker(_via[i], MapMarkerKind.via, label: i + 1),
      if (_end != null) MapMarker(_end!, MapMarkerKind.end),
    ];
    _map.setMarkers(markers);
  }

  void _onLongPress(GeoPoint p) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.play_circle, color: Color(0xFF2E9E44)),
              title: const Text('Set as start'),
              onTap: () => _setPoint(ctx, p, _WaypointRole.start),
            ),
            ListTile(
              leading: const Icon(Icons.flag, color: Color(0xFFC62828)),
              title: const Text('Set as destination'),
              onTap: () => _setPoint(ctx, p, _WaypointRole.end),
            ),
            ListTile(
              leading: const Icon(Icons.add_location_alt,
                  color: Color(0xFFF9A825)),
              title: const Text('Add via point'),
              onTap: () => _setPoint(ctx, p, _WaypointRole.via),
            ),
            if (_start != null || _end != null || _via.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.clear_all),
                title: const Text('Clear all points'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  setState(() {
                    _start = null;
                    _end = null;
                    _via.clear();
                    _route = null;
                    _maneuvers = const [];
                    _routeError = null;
                  });
                  _map.setRoute(const []);
                  _syncMarkers();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _setPoint(BuildContext sheetCtx, GeoPoint p, _WaypointRole role) {
    Navigator.of(sheetCtx).pop();
    setState(() {
      switch (role) {
        case _WaypointRole.start:
          _start = p;
        case _WaypointRole.end:
          _end = p;
        case _WaypointRole.via:
          _via.add(p);
      }
      // Existing route no longer matches the waypoints.
      _route = null;
      _maneuvers = const [];
      _routeError = null;
    });
    _map.setRoute(const []);
    _syncMarkers();
    if (_start != null && _end != null) _computeRoute();
  }

  // ----------------------------------------------------------------- routing

  Future<void> _computeRoute() async {
    final from = _start;
    final to = _end;
    if (from == null || to == null) return;
    final bundle = _app.activeBundle;
    if (bundle == null || !bundle.hasGraph) {
      setState(() =>
          _routeError = 'No active offline bundle — import one in Settings.');
      return;
    }
    setState(() {
      _routing = true;
      _routeError = null;
    });
    final outcome = await computeRouteInIsolate(
      bundleDir: bundle.dir,
      from: from,
      to: to,
      via: List.of(_via),
      profile: _profile,
    );
    if (!mounted) return;
    setState(() => _routing = false);
    final route = outcome.route;
    if (route == null) {
      setState(() => _routeError = outcome.error ?? 'No route found');
      _map.setRoute(const []);
      return;
    }
    setState(() {
      _route = route;
      _routeError = null;
      _maneuvers = nav.buildManeuvers(route);
    });
    _map.setRoute(route.points);
    if (route.points.length >= 2) {
      _map.fitBounds(GeoBounds.of(route.points), _mapSize(context));
    }
  }

  Size _mapSize(BuildContext context) {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : const Size(400, 700);
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final route = _route;
    return Scaffold(
      body: Stack(
        children: [
          OfflineMap(
            controller: _map,
            onLongPress: _onLongPress,
          ),
          // Search bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.search),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            decoration: const InputDecoration(
                              hintText: 'Search offline places…',
                              border: InputBorder.none,
                            ),
                            onChanged: _onSearchChanged,
                            onSubmitted: _runSearch,
                          ),
                        ),
                        if (_searching)
                          const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                        else if (_searchCtrl.text.isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _results = const []);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                if (_results.isNotEmpty)
                  Card(
                    elevation: 6,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _results.length,
                        itemBuilder: (ctx, i) {
                          final r = _results[i];
                          return ListTile(
                            dense: true,
                            title: Text(r.name),
                            subtitle: Text(r.kind),
                            trailing: Text(fmtDistance(
                                r.point.distanceTo(_map.center))),
                            onTap: () {
                              setState(() => _results = const []);
                              _map.centerOn(r.point,
                                  zoom: _map.zoom < 14 ? 15 : _map.zoom);
                              FocusScope.of(context).unfocus();
                            },
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Profile picker
          Positioned(
            top: MediaQuery.of(context).padding.top + 68,
            left: 12,
            right: 12,
            child: SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final p in Profile.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(profileLabel(p)),
                        selected: _profile == p,
                        onSelected: (_) {
                          setState(() => _profile = p);
                          if (_start != null && _end != null) _computeRoute();
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Zoom / locate controls
          Positioned(
            right: 12,
            bottom: route != null ? 190 : 90,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'locate',
                  onPressed: () async {
                    final fix = await _app.location.current();
                    if (fix != null) {
                      _map.centerOn(GeoPoint(fix.lat, fix.lon),
                          zoom: _map.zoom < 13 ? 15 : _map.zoom);
                    }
                  },
                  child: const Icon(Icons.my_location),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'zin',
                  onPressed: () => _map.zoomBy(1),
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'zout',
                  onPressed: () => _map.zoomBy(-1),
                  child: const Icon(Icons.remove),
                ),
              ],
            ),
          ),
          // Routing progress
          if (_routing)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(),
            ),
          // Error banner
          if (_routeError != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: route != null ? 200 : 96,
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.route),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_routeError!)),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => setState(() => _routeError = null),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Route summary card
          if (route != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Card(
                margin: EdgeInsets.zero,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${fmtDistance(route.distM)}  ·  '
                                '${fmtDuration(route.timeS)}  ·  '
                                '↑${route.ascendM.round()} m ↓${route.descendM.round()} m',
                                style:
                                    Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.format_list_bulleted),
                                label: Text(
                                    '${_maneuvers.length} maneuvers'),
                                onPressed: _maneuvers.isEmpty
                                    ? null
                                    : _showManeuverSheet,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                icon: const Icon(Icons.navigation),
                                label: const Text('Start'),
                                onPressed: _startNavigation,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showManeuverSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (ctx, scroll) {
          return ListView.builder(
            controller: scroll,
            itemCount: _maneuvers.length + 1,
            itemBuilder: (ctx, i) {
              if (i == 0) {
                return const ListTile(
                  title: Text('Turn-by-turn',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                );
              }
              final m = _maneuvers[i - 1];
              final prevDist = i >= 2 ? _maneuvers[i - 2].distFromStartM : 0.0;
              return ListTile(
                leading: Icon(maneuverIcon(m.type)),
                title: Text(m.instruction),
                subtitle: Text(fmtDistance(m.distFromStartM - prevDist)),
                trailing: Text(fmtDistance(m.distFromStartM)),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _map.centerOn(GeoPoint(m.lat, m.lon),
                      zoom: _map.zoom < 15 ? 16 : _map.zoom);
                },
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _startNavigation() async {
    final route = _route;
    if (route == null) return;
    final ok = await _app.startNavigation(route, _profile);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              _app.navigation.startError ?? 'Could not start navigation')));
      return;
    }
    // Switch to the Navigate tab.
    _app.selectTab(1);
  }
}

enum _WaypointRole { start, end, via }
