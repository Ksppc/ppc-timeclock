import 'package:flutter_tts/flutter_tts.dart';

/// Saying it out loud.
///
/// THE RULE THIS FILE LIVES UNDER
/// ------------------------------
/// This runs inside the geofence callback, which is the most dangerous place in
/// the whole app to put anything. On 29 July a single helpful-looking call in
/// that callback — promoteToForeground() — killed the process on EVERY crossing.
/// The fence was firing perfectly and nothing was being written, and it took two
/// days to find because the symptom looked like a broken fence.
///
/// So, three rules, and they are not negotiable:
///
///   1. Speaking happens AFTER the punch is safely queued. Never before.
///   2. Every call is wrapped and every failure is swallowed. A silent phone is
///      a cosmetic fault. A missing punch is somebody's pay.
///   3. Nothing here is ever awaited in a way that can block the punch path.
///
/// And the lesson that matters most from that incident: try/catch protects you
/// from your code, not from the operating system. If text-to-speech turns out to
/// misbehave in a background isolate, no amount of error handling here will save
/// it — the fix would be to delete this file, not to guard it harder.
class Speak {
  static FlutterTts? _tts;

  static Future<FlutterTts?> _engine() async {
    if (_tts != null) return _tts;
    try {
      final t = FlutterTts();
      await t.setLanguage('en-CA');
      await t.setSpeechRate(0.48);   // default is a shade fast for a greeting
      await t.setVolume(1.0);
      await t.setPitch(1.0);
      _tts = t;
      return t;
    } catch (_) {
      return null;
    }
  }

  /// What to say, given the direction and the hour of the day.
  ///
  /// Pure and public so it can be tested and, more usefully, so the settings
  /// screen can show every variant without anyone having to drive anywhere at
  /// six in the morning to hear the first one.
  static String greeting({required String direction, required int hour}) {
    if (direction == 'in') {
      if (hour < 12) return 'Good morning';
      if (hour < 17) return 'Good afternoon';
      return 'Good evening';
    }
    // Leaving.
    if (hour < 12) return 'Enjoy the rest of your morning';
    if (hour < 15) return 'Enjoy the rest of your day';
    if (hour < 21) return 'Have a great evening';
    return 'Goodnight';
  }

  /// Speak the greeting for a punch. Never throws.
  static Future<void> punch({required String direction, DateTime? at}) async {
    try {
      final when = at ?? DateTime.now();
      final words = greeting(direction: direction, hour: when.hour);
      final t = await _engine();
      if (t == null) return;
      await t.stop();          // don't stack on top of a previous one
      await t.speak(words);
    } catch (_) {
      // Deliberately silent. See the rules at the top of this file.
    }
  }

  /// For the test button. Same path as the real thing, chosen hour.
  static Future<void> preview(String direction, int hour) async {
    try {
      final t = await _engine();
      if (t == null) return;
      await t.stop();
      await t.speak(greeting(direction: direction, hour: hour));
    } catch (_) {}
  }
}
