/// App settings — persisted as JSON in the app documents directory.
/// ChangeNotifier-based; no external state-management dependency (SPEC §7.4).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared/shared.dart' show Profile;

class AppSettings extends ChangeNotifier {
  static const _fileName = 'settings.json';

  final String _dir;

  AppSettings(this._dir);

  Profile _defaultProfile = Profile.trekking;
  bool _voiceEnabled = true;
  ThemeMode _themeMode = ThemeMode.system;
  bool _darkMap = false;
  String? _activeBundle;

  Profile get defaultProfile => _defaultProfile;
  bool get voiceEnabled => _voiceEnabled;
  ThemeMode get themeMode => _themeMode;
  bool get darkMap => _darkMap;

  /// Directory name (under <docs>/bundles) of the activated offline bundle.
  String? get activeBundle => _activeBundle;

  File get _file => File('$_dir/$_fileName');

  Future<void> load() async {
    try {
      if (!await _file.exists()) return;
      final j = jsonDecode(await _file.readAsString());
      if (j is! Map) return;
      final p = j['defaultProfile'];
      if (p is String) {
        for (final v in Profile.values) {
          if (v.name == p) _defaultProfile = v;
        }
      }
      if (j['voiceEnabled'] is bool) _voiceEnabled = j['voiceEnabled'] as bool;
      if (j['darkMap'] is bool) _darkMap = j['darkMap'] as bool;
      if (j['activeBundle'] is String) _activeBundle = j['activeBundle'] as String;
      switch (j['themeMode']) {
        case 'light':
          _themeMode = ThemeMode.light;
        case 'dark':
          _themeMode = ThemeMode.dark;
        default:
          _themeMode = ThemeMode.system;
      }
      notifyListeners();
    } on Exception {
      // Corrupt settings: keep defaults.
    }
  }

  Future<void> _save() async {
    final j = {
      'defaultProfile': _defaultProfile.name,
      'voiceEnabled': _voiceEnabled,
      'darkMap': _darkMap,
      'themeMode': _themeMode.name,
      'activeBundle': _activeBundle,
    };
    try {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(j));
      await tmp.rename(_file.path);
    } on Exception {
      // best-effort persistence
    }
  }

  void setDefaultProfile(Profile p) {
    _defaultProfile = p;
    notifyListeners();
    _save();
  }

  void setVoiceEnabled(bool v) {
    _voiceEnabled = v;
    notifyListeners();
    _save();
  }

  void setThemeMode(ThemeMode m) {
    _themeMode = m;
    notifyListeners();
    _save();
  }

  void setDarkMap(bool v) {
    _darkMap = v;
    notifyListeners();
    _save();
  }

  void setActiveBundle(String? name) {
    _activeBundle = name;
    notifyListeners();
    _save();
  }
}
