import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Tell the person what just happened to their clock.
///
/// WHY THIS EXISTS
/// ---------------
/// A wrong punch used to be discovered by the admin, in a payroll query, days
/// later — by which point nobody remembers whether they really did leave at
/// 4:26 or 4:40. Told at the moment it happens, it is found by the one person
/// who was actually there and still remembers.
///
/// That is principle five — silent failure is the enemy — pointed at the people
/// best placed to catch it. It turns the whole crew into error detectors
/// instead of leaving one person auditing after the fact.
///
/// THE ONE RULE THAT MATTERS
/// -------------------------
/// A notification must NEVER be able to cost a punch. It is sent AFTER the
/// punch is safely written, and every call is wrapped so a failure here is
/// swallowed. We already lost a whole architecture to a cosmetic-looking call
/// at the top of the geofence callback — promoteToForeground(), which killed
/// the process before it could write anything. Notifications go last, and they
/// go quietly.
///
/// BUILD NOTE
/// ----------
/// flutter_local_notifications requires core library desugaring. That is
/// enabled in the build workflow, and enabling it correctly means adding ONLY
/// the desugaring flag and library — not touching sourceCompatibility or
/// kotlinOptions, both of which are already consistent at Java 17 in the
/// Flutter scaffold. Overriding either of them breaks the build.
class Notify {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Safe to call from any isolate; the geofence callback runs in a fresh one
  /// where nothing has been set up.
  static Future<void> _init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      _ready = true;
    } catch (_) {
      // Leave _ready false; a later call can try again.
    }
  }

  /// THE CHANNEL ID MUST CHANGE WHENEVER THE SOUND OR IMPORTANCE CHANGES.
  ///
  /// Android freezes a channel's sound, importance and vibration the first time
  /// the channel is created, and after that the SETTINGS BELOW ARE IGNORED
  /// forever on that install. Ship a new sound under the old id and the phone
  /// keeps playing the old one — you get a silent, working build that looks
  /// broken and sends you hunting through code that is already correct.
  ///
  /// So the id carries a suffix. Bump it, don't edit it.
  ///   ppc_punches      — original, silent
  ///   ppc_punches_v2   — cash register, high importance   <- current
  static const _channelId = 'ppc_punches_v2';

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      'Clock in and out',
      sound: RawResourceAndroidNotificationSound('kaching'),
      channelDescription:
          'Tells you when the app has clocked you in or out at the shop.',
      importance: Importance.high,
      priority: Priority.high,
      // Audible and felt, on purpose.
      //
      // These started silent, on the reasoning that nobody needs their phone
      // buzzing when they park. That reasoning was wrong, and the 31 July
      // incident is why: the app clocked Kent in 33 times and every one of
      // those punches raised a notification he never heard. A silent alert
      // about a payroll error is a log entry, not a warning.
      //
      // Two of these a day is not noise. It is the only moment the person is
      // standing there able to say "that is wrong" while they still remember.
      playSound: true,
      enableVibration: true,
    ),
  );

  /// [direction] is 'in' or 'out'. [at] is the PUNCH time, not the time this
  /// notification happens to be shown — those differ by minutes when Android
  /// delivers a crossing late, and the punch time is the one that gets paid.
  static Future<void> punch({
    required String direction,
    required DateTime at,
    required String mechanism,
  }) async {
    try {
      await _init();
      if (!_ready) return;

      final hh = at.hour.toString().padLeft(2, '0');
      final mm = at.minute.toString().padLeft(2, '0');
      final isIn = direction == 'in';

      final title = isIn ? 'Clocked in — $hh:$mm' : 'Clocked out — $hh:$mm';
      final body = isIn
          ? 'You are on the clock at the shop. If that is wrong, tell Kent.'
          : 'Your shift has been closed. If you are still working, tell Kent.';

      // Separate IDs for in and out, so an arrival notification is not
      // silently replaced by a departure one later in the day.
      await _plugin.show(isIn ? 1001 : 1002, title, body, _details,
          payload: mechanism);
    } catch (_) {
      // The punch is already saved by the time we get here. Never throw.
    }
  }
}
