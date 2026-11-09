/// Navigate screen (SPEC §7): next-maneuver banner (icon + instruction +
/// distance), live position/heading on the offline map, remaining
/// distance/ETA, voice prompts via TtsAdapter, reroute indicator.
library;

import 'package:flutter/material.dart';
import 'package:nav_engine/nav_engine.dart' as nav;

import '../app_state.dart';
import '../map/offline_map.dart';
import '../widgets/format.dart';

class NavigateScreen extends StatefulWidget {
  const NavigateScreen({super.key});

  @override
  State<NavigateScreen> createState() => _NavigateScreenState();
}

class _NavigateScreenState extends State<NavigateScreen> {
  final OfflineMapController _map = OfflineMapController();

  AppState get _app => AppState.instance;

  @override
  void initState() {
    super.initState();
    _map.tileSource = _app.tiles;
    _map.followPosition = true;
    _app.navigation.addListener(_onNav);
  }

  @override
  void dispose() {
    _app.navigation.removeListener(_onNav);
    super.dispose();
  }

  void _onNav() {
    final n = _app.navigation;
    final pos = n.position;
    if (pos != null) {
      _map.updatePosition(pos, n.headingDeg);
      if (_map.zoom < 14) {
        _map.setViewport(pos, 16);
      }
    }
    _map.setRoute(n.currentRoute?.points ?? const []);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final n = _app.navigation;
    if (!n.active) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.navigation, size: 56),
                const SizedBox(height: 16),
                Text(
                  n.startError ??
                      'No active navigation.\nPlan a route on the Map tab and tap Start.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  icon: const Icon(Icons.map),
                  label: const Text('Open planner'),
                  onPressed: () => _app.selectTab(0),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final state = n.state;
    final maneuver = state?.next;
    return Scaffold(
      body: Stack(
        children: [
          OfflineMap(controller: _map),
          // Maneuver banner
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            right: 12,
            child: Card(
              elevation: 6,
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      maneuverIcon(
                          maneuver?.type ?? nav.ManeuverType.depart),
                      size: 40,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            maneuver == null
                                ? (n.arrived
                                    ? 'You have arrived'
                                    : 'Follow the route')
                                : maneuver.instruction,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          if (maneuver != null && state != null)
                            Text(
                              fmtDistance(state.distToNextManeuverM),
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Rerouting indicator
          if (state?.rerouting ?? false)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(),
            ),
          if (state?.rerouting ?? false)
            Positioned(
              top: MediaQuery.of(context).padding.top + 100,
              left: 12,
              right: 12,
              child: const Card(
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 8),
                      Text('Recalculating route…'),
                    ],
                  ),
                ),
              ),
            ),
          // Off-route warning
          if ((state?.offRouteDistM ?? 0) > 25 && !(state?.rerouting ?? false))
            Positioned(
              top: MediaQuery.of(context).padding.top + 100,
              left: 12,
              right: 12,
              child: Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wrong_location),
                      SizedBox(width: 8),
                      Text('Off route — returning you to the course'),
                    ],
                  ),
                ),
              ),
            ),
          // Bottom status bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Card(
              margin: EdgeInsets.zero,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      _Stat(
                          label: 'Remaining',
                          value: fmtDistance(state?.remainingM ?? 0)),
                      _Stat(label: 'ETA', value: fmtEta(state?.etaS ?? 0)),
                      _Stat(
                        label: 'Off route',
                        value: (state?.offRouteDistM ?? 0) < 25
                            ? '—'
                            : fmtDistance(state!.offRouteDistM),
                      ),
                      const Spacer(),
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.stop),
                        label: const Text('End'),
                        onPressed: () async {
                          await _app.navigation.stop();
                          if (mounted) setState(() {});
                        },
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
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: Theme.of(context).textTheme.titleLarge),
          Text(label, style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}
