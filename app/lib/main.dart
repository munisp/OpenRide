/// OpenRide — fully offline route planner / navigator / ride recorder.
/// Bottom-nav shell with the five SPEC §7 screens.
library;

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'screens/history_screen.dart';
import 'screens/map_planner_screen.dart';
import 'screens/navigate_screen.dart';
import 'screens/record_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OpenRideApp());
}

class OpenRideApp extends StatefulWidget {
  const OpenRideApp({super.key});

  @override
  State<OpenRideApp> createState() => _OpenRideAppState();
}

class _OpenRideAppState extends State<OpenRideApp> {
  @override
  void initState() {
    super.initState();
    AppState.instance.init();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([app, ...?appReadySettings(app)]),
      builder: (context, _) {
        if (!app.initialized) {
          return const MaterialApp(
            home: Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.directions_bike, size: 64),
                    SizedBox(height: 16),
                    Text('OpenRide', style: TextStyle(fontSize: 24)),
                    SizedBox(height: 16),
                    CircularProgressIndicator(),
                  ],
                ),
              ),
            ),
          );
        }
        return MaterialApp(
          title: 'OpenRide',
          debugShowCheckedModeBanner: false,
          themeMode: app.settings.themeMode,
          theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF2E7D32),
            brightness: Brightness.light,
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFF2E7D32),
            brightness: Brightness.dark,
          ),
          home: const BottomNavShell(),
        );
      },
    );
  }

  /// Settings is only available after init; merge it in when ready.
  List<Listenable>? appReadySettings(AppState app) =>
      app.initialized ? [app.settings] : null;
}

/// The five-tab shell: Map/Planner, Navigate, Record, History, Settings.
/// IndexedStack keeps every screen alive (recording/navigation keep running
/// when switching tabs). Tab selection lives in [AppState.selectedTab].
class BottomNavShell extends StatelessWidget {
  const BottomNavShell({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return AnimatedBuilder(
      animation: Listenable.merge(
          [app.selectedTab, app.navigation, app.recording]),
      builder: (context, _) {
        final tab = app.selectedTab.value;
        return Scaffold(
          body: IndexedStack(
            index: tab,
            children: const [
              MapPlannerScreen(),
              NavigateScreen(),
              RecordScreen(),
              HistoryScreen(),
              SettingsScreen(),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: app.selectTab,
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.map), label: 'Plan'),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: app.navigation.active,
                  smallSize: 8,
                  child: const Icon(Icons.navigation),
                ),
                label: 'Navigate',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: app.recording.isActive,
                  smallSize: 8,
                  child: const Icon(Icons.fiber_manual_record),
                ),
                label: 'Record',
              ),
              const NavigationDestination(
                  icon: Icon(Icons.history), label: 'History'),
              const NavigationDestination(
                  icon: Icon(Icons.settings), label: 'Settings'),
            ],
          ),
        );
      },
    );
  }
}
