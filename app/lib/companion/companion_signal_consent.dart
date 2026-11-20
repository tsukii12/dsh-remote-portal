// What she may bring up in her room about other conversations (C902's four
// consents), one setting for this installation. Only local lines come of it:
// nothing here is sent to a model.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'companion_signals.dart';

const _consentKey = 'companion_signal_consent';

extension CompanionSignalConsentCopy on CompanionSignalConsent {
  CompanionSignalConsent copyWith({bool? state, bool? optionalSpeech, bool? voice, bool? nightCare}) =>
      CompanionSignalConsent(
        state: state ?? this.state,
        optionalSpeech: optionalSpeech ?? this.optionalSpeech,
        voice: voice ?? this.voice,
        nightCare: nightCare ?? this.nightCare,
      );
}

/// Null until read: an unread setting lets nothing in.
class CompanionSignalConsentSettings extends Notifier<CompanionSignalConsent?> {
  /// As close to the room before the gate as it allows: she keeps track and
  /// may say a line; her voice and the late-night reminder wait for a yes.
  static const defaults = CompanionSignalConsent(state: true, optionalSpeech: true);

  @override
  CompanionSignalConsent? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ref.mounted && state == null) state = _read(prefs.getString(_consentKey)) ?? defaults;
    } on Object {
      // Stays null: nothing comes in on a setting nobody could read.
    }
  }

  /// Null only when nothing was ever saved. A damaged record lets nothing
  /// in: the defaults must not undo an earlier no.
  static CompanionSignalConsent? _read(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return const CompanionSignalConsent();
      bool flag(String key) => map[key] == true;
      return CompanionSignalConsent(
        state: flag('state'),
        optionalSpeech: flag('optionalSpeech'),
        voice: flag('voice'),
        nightCare: flag('nightCare'),
      );
    } on FormatException {
      return const CompanionSignalConsent();
    }
  }

  Future<void> set(CompanionSignalConsent consent) async {
    state = consent;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _consentKey,
      jsonEncode({
        'state': consent.state,
        'optionalSpeech': consent.optionalSpeech,
        'voice': consent.voice,
        'nightCare': consent.nightCare,
      }),
    );
  }
}

final companionSignalConsentProvider = NotifierProvider<CompanionSignalConsentSettings, CompanionSignalConsent?>(
  CompanionSignalConsentSettings.new,
);
