/// Foreground service bridge (Android) — keeps ride recording alive with a
/// persistent notification. On iOS this is a no-op (background location is
/// handled via UIBackgroundModes). Native side: RecordingService.kt.
library;

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class ForegroundServiceBridge {
  static const MethodChannel _channel =
      MethodChannel('openride/foreground_service');

  static bool get _supported => Platform.isAndroid;

  /// Starts the foreground service with a "recording" notification.
  /// Also requests POST_NOTIFICATIONS implicitly handled by the caller.
  static Future<void> startRecording() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('start', {
        'title': 'OpenRide',
        'text': 'Recording ride…',
      });
    } on PlatformException {
      // Notification permission denied or service unavailable; recording
      // still works while the app is in the foreground.
    } on MissingPluginException {
      // Native host not wired (e.g. running without flutter create output).
    }
  }

  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // ignore
    } on MissingPluginException {
      // ignore
    }
  }
}
