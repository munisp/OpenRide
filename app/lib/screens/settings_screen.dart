/// Settings screen (SPEC §7): default routing profile, voice on/off, theme
/// override, and the Offline Data manager (import .osm.pbf via file_picker →
/// background-isolate bundle build; list / activate / delete bundles with
/// bounds + size).
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared/shared.dart' show Profile;

import '../app_state.dart';
import '../data/bundle_manager.dart';
import '../widgets/format.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppState get _app => AppState.instance;

  @override
  void initState() {
    super.initState();
    _app.settings.addListener(_onChange);
    _app.bundles.addListener(_onChange);
    _app.addListener(_onChange);
  }

  @override
  void dispose() {
    _app.settings.removeListener(_onChange);
    _app.bundles.removeListener(_onChange);
    _app.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final settings = _app.settings;
    final bundles = _app.bundles.list();
    final activeName = settings.activeBundle;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _sectionTitle(context, 'Routing'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.route),
              title: const Text('Default profile'),
              subtitle: Text(profileLabel(settings.defaultProfile)),
              trailing: DropdownButton<Profile>(
                value: settings.defaultProfile,
                underline: const SizedBox.shrink(),
                onChanged: (p) {
                  if (p != null) settings.setDefaultProfile(p);
                },
                items: [
                  for (final p in Profile.values)
                    DropdownMenuItem(value: p, child: Text(profileLabel(p))),
                ],
              ),
            ),
          ),
          _sectionTitle(context, 'Navigation voice'),
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.record_voice_over),
              title: const Text('Voice prompts'),
              subtitle: const Text(
                  'Spoken turn instructions via the device TTS engine'),
              value: settings.voiceEnabled,
              onChanged: settings.setVoiceEnabled,
            ),
          ),
          _sectionTitle(context, 'Appearance'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.brightness_6),
                  title: const Text('App theme'),
                  trailing: DropdownButton<ThemeMode>(
                    value: settings.themeMode,
                    underline: const SizedBox.shrink(),
                    onChanged: (m) {
                      if (m != null) settings.setThemeMode(m);
                    },
                    items: const [
                      DropdownMenuItem(
                          value: ThemeMode.system, child: Text('System')),
                      DropdownMenuItem(
                          value: ThemeMode.light, child: Text('Light')),
                      DropdownMenuItem(
                          value: ThemeMode.dark, child: Text('Dark')),
                    ],
                  ),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.map),
                  title: const Text('Dark map'),
                  subtitle: const Text('Dark render theme for the offline map'),
                  value: settings.darkMap,
                  onChanged: settings.setDarkMap,
                ),
              ],
            ),
          ),
          _sectionTitle(context, 'Offline data'),
          if (_app.bundles.importing)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                          'Building bundle from ${_app.bundles.importingName ?? 'file'}…\n'
                          'This can take several minutes for large extracts.'),
                    ),
                  ],
                ),
              ),
            ),
          if (bundles.isEmpty && !_app.bundles.importing)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No offline data yet. Import an .osm.pbf extract (e.g. from '
                  'Geofabrik) to enable routing, maps and place search.\n\n'
                  'Everything is processed on-device; no data leaves the phone.',
                ),
              ),
            ),
          for (final b in bundles) _bundleTile(context, b, activeName),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.file_open),
            label: const Text('Import .osm.pbf extract'),
            onPressed: _app.bundles.importing ? null : _importBundle,
          ),
          const SizedBox(height: 24),
          Text(
            'OpenRide stores bundles and rides under:\n${_app.documentsDir}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(t, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _bundleTile(BuildContext context, BundleInfo b, String? activeName) {
    final active = b.name == activeName;
    final bounds = b.bounds;
    return Card(
      child: ListTile(
        leading: Icon(
          active ? Icons.check_circle : Icons.circle_outlined,
          color: active ? Theme.of(context).colorScheme.primary : null,
        ),
        title: Text(b.name, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${fmtBytes(b.sizeBytes)}'
          '${bounds != null ? '\nlat ${bounds.minLat.toStringAsFixed(2)}…${bounds.maxLat.toStringAsFixed(2)}, '
              'lon ${bounds.minLon.toStringAsFixed(2)}…${bounds.maxLon.toStringAsFixed(2)}' : ''}'
          '${b.generatedAt != null ? '\nbuilt ${_fmtDate(b.generatedAt!)}' : ''}'
          '${!b.isUsable ? '\nIncomplete bundle' : ''}',
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          onSelected: (action) async {
            switch (action) {
              case 'activate':
                await _app.activateBundle(b.name);
              case 'delete':
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete bundle?'),
                    content: Text(
                        '${b.name} (${fmtBytes(b.sizeBytes)}) will be removed from the device.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Delete')),
                    ],
                  ),
                );
                if (ok == true) await _app.deleteBundle(b.name);
            }
          },
          itemBuilder: (ctx) => [
            if (!active && b.isUsable)
              const PopupMenuItem(value: 'activate', child: Text('Activate')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: active || !b.isUsable
            ? null
            : () => _app.activateBundle(b.name),
      ),
    );
  }

  Future<void> _importBundle() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pbf'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not access the picked file.')));
      }
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      final info = await _app.bundles.importPbf(path);
      // Auto-activate the first (or only) bundle.
      if (_app.settings.activeBundle == null) {
        await _app.activateBundle(info.name);
      }
      messenger.showSnackBar(
          SnackBar(content: Text('Bundle "${info.name}" ready.')));
    } on Exception catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Import failed: $e')));
    }
  }

  static String _fmtDate(DateTime t) {
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
  }
}
