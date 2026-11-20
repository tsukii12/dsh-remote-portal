import 'package:flutter/services.dart';

// Share one native subscription between dictation events and optional call/dictation PCM.
final voicePlatformEvents = const EventChannel('dsh/voice/events').receiveBroadcastStream();
