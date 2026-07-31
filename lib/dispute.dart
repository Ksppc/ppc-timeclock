import 'package:supabase_flutter/supabase_flutter.dart' hide Presence;
import 'identity.dart';

/// Letting the crew say "that's wrong".
///
/// WHY
/// ---
/// Until now only the admin could correct anything, and only if they noticed.
/// The person whose pay is wrong is the person most likely to spot it and the
/// least able to do anything about it. Every commercial product in this
/// category ships an edit-request path with reason capture and an approval
/// queue; this had none.
///
/// WHAT IT DELIBERATELY DOES NOT DO
/// --------------------------------
/// A report NEVER changes hours. It raises a flag; a human decides.
///
/// That is not timidity, it is the only honest design available here: the app
/// runs on the public anon key, so the database cannot tell one crew member
/// from another. If a report could move time, any handset could move anyone's
/// time. So reports are claims, and claims get reviewed.
class Dispute {
  /// File a report against a day. Returns true if it reached the server.
  ///
  /// [note] is free text and required — the useful detail is always the bit no
  /// dropdown anticipated ("truck wouldn't start, sat in the yard till 8").
  /// The claimed times are optional: "something is wrong and I don't know
  /// what" is a legitimate and useful report.
  static Future<bool> file({
    required DateTime workDate,
    required String note,
    String? claimedIn,
    String? claimedOut,
  }) async {
    try {
      final d = workDate;
      final ymd = '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      await Supabase.instance.client.from('punch_disputes').insert({
        'employee_id': await Identity.effectiveId(),
        'work_date': ymd,
        'note': note.trim(),
        'claimed_in': (claimedIn ?? '').trim().isEmpty ? null : claimedIn,
        'claimed_out': (claimedOut ?? '').trim().isEmpty ? null : claimedOut,
      });
      return true;
    } catch (_) {
      // Offline or refused. The caller tells the person plainly rather than
      // pretending it went through — a report they believe was filed and was
      // not is worse than no report at all.
      return false;
    }
  }
}
