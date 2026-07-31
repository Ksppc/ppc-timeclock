import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Tell the person what just happened to their clock.
///
/// WHY THIS EXISTS
/// ---------------
/// Until 30 July a wrong punch was discovered by the admin, in a payroll query,
/// days after the fact — by which point nobody remembers whether they really
/// did leave at 4:26 or 4:40. Telling the person at the moment it happens moves
/// discovery to the one human who was actually there and still remembers.
///
/// Every commercial product in this category does this. It is also principle
/// five — silent failure is the enemy — pointed at the people best placed to
/// catch it.
///
/// THE ONE RULE THAT MATTERS
/// -------------------------
/// A notification must NEVER be able to cost a punch. It is always sent AFTER
/// the punch is safely written, and every call is wrapped so a failure here is
/// swallowed. We already lost a whole architecture to a cosmetic-looking call
/// at the top of the geofence callback — promoteToForeground(), which killed
/// the process before it could write anything. Notifications go last, and they
/// go quietly.
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
      // Leave _ready false; the next attempt can try again.
    }
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'ppc_punches',
      'Clock in and out',
      channelDescription:
          'Tells you when the app has clocked you in or out at the shop.',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      // Not ongoing, not silent-by-default: this is information the person is
      // entitled to see, but it is not an emergency.
      playSound: false,
      enableVibration: false,
    ),
  );

  /// [direction] is 'in' or 'out'. [at] is the punch time, not the time this
  /// notification happens to be shown — those can differ by minutes when the
  /// OS delivers a crossing late, and showing the punch time is the honest one.
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

      // Say plainly what happened and what to do if it is wrong. "Tell Kent"
      // is a real instruction; "contact your administrator" is not.
      final title = isIn ? 'Clocked in — $hh:$mm' : 'Clocked out — $hh:$mm';
      final body = isIn
          ? 'You are on the clock at the shop. If that is wrong, open the app '
              'and report it.'
          : 'Your shift has been closed. If you are still working, open the '
              'app and report it.';

      await _plugin.show(isIn ? 1001 : 1002, title, body, _details,
          payload: mechanism);
    } catch (_) {
      // A punch is already saved by the time we get here. Never let this throw.
    }
  }
}
