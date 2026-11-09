/// TtsAdapter — wraps `flutter_tts` behind a settings flag (SPEC §7).
/// Voice prompts are queued and spoken sequentially; when disabled, prompts
/// are silently dropped.
library;

import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

abstract class TtsAdapter {
  bool get enabled;
  set enabled(bool value);

  /// Speak [text] when enabled. Returns immediately; utterances are queued.
  Future<void> speak(String text);
  Future<void> stop();
}

class FlutterTtsAdapter implements TtsAdapter {
  final FlutterTts _tts = FlutterTts();

  @override
  bool enabled;

  bool _speaking = false;
  final List<String> _queue = [];

  FlutterTtsAdapter({this.enabled = true}) {
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await _tts.setSpeechRate(0.52);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
      // Keep call sites non-blocking.
      await _tts.awaitSpeakCompletion(false);
    } on Exception {
      // TTS engine missing on the device; prompts will be dropped.
      enabled = false;
    }
  }

  @override
  Future<void> speak(String text) async {
    if (!enabled || text.trim().isEmpty) return;
    _queue.add(text);
    if (_speaking) return;
    _speaking = true;
    try {
      while (_queue.isNotEmpty) {
        if (!enabled) {
          _queue.clear();
          break;
        }
        final next = _queue.removeAt(0);
        try {
          await _tts.speak(next);
          // awaitSpeakCompletion is off; give the engine a beat between
          // utterances to avoid truncation on some Android engines.
          await Future<void>.delayed(const Duration(milliseconds: 250));
        } on Exception {
          // drop failed utterance, continue with the queue
        }
      }
    } finally {
      _speaking = false;
    }
  }

  @override
  Future<void> stop() async {
    _queue.clear();
    try {
      await _tts.stop();
    } on Exception {
      // ignore
    }
  }
}

/// Avoids unawaited-futures lint without depending on package:pedantic.
void unawaited(Future<void> f) {}
