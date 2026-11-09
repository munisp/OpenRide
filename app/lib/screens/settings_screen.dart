/// Settings screen (SPEC §7): default profile, voice, theme, Offline Data
/// bundle manager (import .osm.pbf via file_picker → background isolate
/// build, activate, delete).
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
  }

  @override
  void dispose() {
    _app.settings.removeListener(_onChange);
    _app.bundles.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = _app.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SectionHeader('Routing'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: DropdownButtonFormField<Profile>(
              initialValue: s.defaultProfile,
              decoration: const InputDecoration(
                labelText: 'Default profile',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final p in Profile.values)
                  DropdownMenuItem(value: p, child: Text(profileLabel(p))),
              ],
              onChanged: (p) {
                if (p != null) s.setDefaultProfile(p);
              },
            ),
          ),
          _SectionHeader('Navigation'),
          SwitchListTile(
            secondary: const Icon(Icons.record_voice_over),
            title: const Text('Voice prompts'),
            subtitle: const Text('Spoken turn instructions via device TTS'),
            value: s.voiceEnabled,
            onChanged: s.setVoiceEnabled,
          ),
          _SectionHeader('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: DropdownButtonFormField<ThemeMode>(
              initialValue: s.themeMode,
              decoration: const InputDecoration(
                labelText: 'App theme',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                    value: ThemeMode.system, child: Text('System default')),
                DropdownMenuItem(
                    value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(
                    value: ThemeMode.dark, child: Text('Dark')),
              ],
              onChanged: (m) {
                if (m != null) s.setThemeMode(m);
              },
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.map_outlined),
            title: const Text('Dark map'),
            subtitle: const Text('Dark render theme for the offline map'),
            value: s.darkMap,
            onChanged: s.setDarkMap,
          ),
          const Divider(),
          _SectionHeader('Offline data'),
          _BundleSection(app: _app, onChanged: _onChange),
          const Divider(),
          const _AboutSection(),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _BundleSection extends StatelessWidget {
  final AppState app;
  final VoidCallback onChanged;

  const _BundleSection({required this.app, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final bm = app.bundles;
    final bundles = bm.list();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (bm.importing)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                    'Building offline bundle from ${bm.importingName}…\nThis can take several minutes for large extracts.'),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: FilledButton.icon(
              icon: const Icon(Icons.file_open),
              label: const Text('Import .osm.pbf extract'),
              onPressed: () => _import(context),
            ),
          ),
        if (bm.lastImportError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Last import failed: ${bm.lastImportError}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (bundles.isEmpty && !bm.importing)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No offline data yet. Routing, maps and search need a bundle built '
              'from an .osm.pbf extract (e.g. Geofabrik). Import happens fully '
              'on-device in a background isolate.',
            ),
          ),
        for (final b in bundles)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ListTile(
              leading: Icon(
                Icons.folder_zip,
                color: app.settings.activeBundle == b.name
                    ? Colors.green
                    : null,
              ),
              title: Text(b.name),
              subtitle: Text(
                _bundleSubtitle(b) +
                    (b.isUsable ? '' : '\nIncomplete bundle (re-import)'),
              ),
              isThreeLine: true,
              trailing: PopupMenuButton<String>(
                onSelected: (action) => _bundleAction(context, b, action),
                itemBuilder: (ctx) => [
                  if (app.settings.activeBundle != b.name && b.isUsable)
                    const PopupMenuItem(
                        value: 'activate', child: Text('Activate')),
                  const PopupMenuItem(
                      value: 'delete', child: Text('Delete')),
                ],
              ),
              onTap: b.isUsable && app.settings.activeBundle != b.name
                  ? () => _bundleAction(context, b, 'activate')
                  : null,
            ),
          ),
      ],
    );
  }

  String _bundleSubtitle(BundleInfo b) {
    final parts = <String>[fmtBytes(b.sizeBytes)];
    if (b.generatedAt != null) {
      final t = b.generatedAt!.toLocal();
      parts.add(
          'built ${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}');
    }
    if (b.bounds != null) {
      parts.add(
          '${b.bounds!.minLat.toStringAsFixed(2)}…${b.bounds!.maxLat.toStringAsFixed(2)} lat');
    }
    if (app.settings.activeBundle == b.name) parts.add('ACTIVE');
    return parts.join(' · ');
  }

  Future<void> _import(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pbf'],
      withData: false,
    );
    final path = result?.files.single.path;
    if (path == null) return;
    try {
      final info = await app.bundles.importPbf(path);
      if (app.settings.activeBundle == null) {
        await app.activateBundle(info.name);
      }
      messenger.showSnackBar(
          SnackBar(content: Text('Bundle "${info.name}" ready.')));
    } on Exception catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
    onChanged();
  }

  Future<void> _bundleAction(
      BuildContext context, BundleInfo b, String action) async {
    switch (action) {
      case 'activate':
        await app.activateBundle(b.name);
        onChanged();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${b.name}?'),
            content:
                Text('Removes ${fmtBytes(b.sizeBytes)} of offline data.'),
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
        if (ok == true) {
          await app.deleteBundle(b.name);
          onChanged();
        }
    }
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    final app = AppState.instance;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('About', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          const Text(
            'OpenRide 1.0.0\n'
            'Fully offline route planner, navigator and ride recorder. '
            'No account. No backend. No analytics. Map data © OpenStreetMap '
            'contributors (ODbL).',
          ),
          const SizedBox(height: 8),
          Text(
            'Data directory: ${app.initialized ? app.documentsDir : '…'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
