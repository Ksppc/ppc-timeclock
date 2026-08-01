import 'package:supabase_flutter/supabase_flutter.dart';
import 'identity.dart';

/// The crew member's own hours, fetched on demand.
///
/// WHY ON DEMAND AND NOT LIVE
/// --------------------------
/// Nothing here runs on a timer, in the background, or from the geofence
/// isolate. It runs when a person taps a button and at no other time.
///
/// That is deliberate. Twice now this app has been broken by code that ran on
/// its own schedule near the punch path -- a foreground-service call in the
/// geofence callback that killed the process on every crossing, and a
/// background clock-state sync that clocked one person in 33 times in a day.
/// Both were additions meant to help. Neither was asked for by a person
/// pressing a button.
///
/// So this file reads. It never writes, never punches, never touches the
/// clocked-in flag, and cannot run unless someone is looking at the screen. If
/// every line of it is wrong, the worst case is a wrong number on a display
/// that nobody is being paid from.
///
/// WHY IT CALLS AN RPC
/// -------------------
/// The app's anon key has no read access to workdays. A direct select would
/// come back as an empty list rather than an error -- the exact silent failure
/// that caused the 33-punch day. crew_summary() is SECURITY DEFINER, so a
/// permissions problem surfaces as a thrown exception we can show the person,
/// instead of a plausible-looking zero.
class CrewHours {
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final double paidHours;
  final double regHours;
  final double otHours;
  final int daysWorked;

  /// 'open' (on the clock now), 'closed' (day finished), 'needs_review'
  /// (something is wrong with today), or 'none' (nothing recorded today).
  final String todayStatus;
  final DateTime? todayFirstIn;
  final DateTime? todayLastOut;
  final double todayHours;

  const CrewHours({
    required this.periodStart,
    required this.periodEnd,
    required this.paidHours,
    required this.regHours,
    required this.otHours,
    required this.daysWorked,
    required this.todayStatus,
    required this.todayFirstIn,
    required this.todayLastOut,
    required this.todayHours,
  });

  /// Fetch this phone's own hours for the current pay period.
  ///
  /// Throws on failure ON PURPOSE. The caller shows the person what went wrong.
  /// Returning a zeroed object on error would show "0.0 hrs" to somebody who
  /// worked all week, and they would believe it -- which is worse than an
  /// error message, because an error message can be reported and a wrong
  /// number just quietly becomes an argument on payday.
  static Future<CrewHours> fetch() async {
    final id = await Identity.effectiveId();
    final rows = await Supabase.instance.client
        .rpc('crew_summary', params: {'p_employee_id': id});

    final list = (rows as List?) ?? const [];
    if (list.isEmpty) {
      throw StateError('The server returned no hours record for this phone.');
    }
    final r = list.first as Map<String, dynamic>;

    double num_(dynamic v) => v == null ? 0.0 : (v as num).toDouble();
    DateTime? date_(dynamic v) =>
        (v == null || v == '') ? null : DateTime.parse(v as String).toLocal();

    return CrewHours(
      periodStart: date_(r['period_start']),
      periodEnd: date_(r['period_end']),
      paidHours: num_(r['paid_hours']),
      regHours: num_(r['reg_hours']),
      otHours: num_(r['ot_hours']),
      daysWorked: (r['days_worked'] as num?)?.toInt() ?? 0,
      todayStatus: (r['today_status'] ?? 'none') as String,
      todayFirstIn: date_(r['today_first_in']),
      todayLastOut: date_(r['today_last_out']),
      todayHours: num_(r['today_hours']),
    );
  }

  /// What today looks like in one line, in plain words.
  String get todayLine {
    String hm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    switch (todayStatus) {
      case 'open':
        return todayFirstIn == null
            ? 'On the clock now.'
            : 'On the clock since ${hm(todayFirstIn!)}.';
      case 'closed':
        final a = todayFirstIn == null ? '?' : hm(todayFirstIn!);
        final b = todayLastOut == null ? '?' : hm(todayLastOut!);
        return '$a to $b — ${todayHours.toStringAsFixed(2)} hrs.';
      case 'needs_review':
        // Never dress this up. A day the server could not make sense of is a
        // day somebody has to look at, and the person it happened to is the
        // one who remembers what actually happened.
        return 'Today did not add up. Tell Kent.';
      default:
        return 'Nothing recorded today yet.';
    }
  }

  /// The pay period as "Jul 19 – Aug 1".
  String get periodLine {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    if (periodStart == null || periodEnd == null) return 'This pay period';
    String d(DateTime x) => '${m[x.month - 1]} ${x.day}';
    return '${d(periodStart!)} – ${d(periodEnd!)}';
  }

  /// True when the totals are zero but days have clearly been worked. That is
  /// not "you worked nothing", it is "nobody has closed your days yet" — the
  /// exact confusion that made the dashboard read 0.0 hrs on 31 July while a
  /// full day of punches sat in the database.
  bool get looksUncomputed =>
      paidHours == 0 && daysWorked == 0 && todayStatus != 'none';
}
